# frozen_string_literal: true

require "rails_helper"

# v0.16 — the pulse monitor: trigger a cycle from the browser, watch it live.
RSpec.describe "Enliterator heartbeat page", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
    end
  end

  describe "GET /enliterator/heartbeat" do
    it "renders the plan + trigger form when nothing is running" do
      Widget.create!(title: "untended", body: "b")
      get "/enliterator/heartbeat"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Next cycle")
        .and include("Beat now")
        .and include("frontier:")                       # the horizon line
        .and include("whole collection — every context, one budget")
    end

    it "renders monitor mode (no form) while a within-window cycle is open" do
      hb = Enliterator::Heartbeat.create!(started_at: 5.minutes.ago, mode: "sync",
                                          budget_tokens: 1000, planned: { "counts" => { "frontier" => 3 } })
      get "/enliterator/heartbeat"
      expect(response.body).to include("Cycle ##{hb.id}").and include("running")
      expect(response.body).not_to include("Beat now")
    end

    it "treats an open row OLDER than the window as crash evidence — the form is back" do
      Enliterator::Heartbeat.create!(started_at: 7.hours.ago, mode: "sync", budget_tokens: 1000)
      get "/enliterator/heartbeat"
      expect(response.body).to include("Beat now")
        .and include("still open — likely crashed")
    end

    it "says the hand-cranked line before any cycle has ever run" do
      get "/enliterator/heartbeat"
      expect(response.body).to include("No cycles yet")
    end
  end

  describe "POST /enliterator/heartbeat/beat" do
    it "opens a cycle, hands it to execute_async!, and redirects to the monitor" do
      Widget.create!(title: "untended", body: "b")
      async_called = nil
      allow_any_instance_of(Enliterator::Heartbeat).to receive(:execute_async!) do |row, plan|
        async_called = [ row.id, plan.items.size ]
        Thread.new {}
      end

      post "/enliterator/heartbeat/beat", params: { budget: 5_000 }
      expect(response).to redirect_to("/enliterator/heartbeat")

      row = Enliterator::Heartbeat.order(:id).last
      expect(row.budget_tokens).to eq(5_000)
      expect(row.finished_at).to be_nil
      expect(async_called).to eq([ row.id, row.planned_count ])
      follow_redirect!
      expect(response.body).to include("Heartbeat ##{row.id} started")
    end

    it "clamps the budget to the configured default — a stray zero can't authorize a mega-cycle" do
      allow_any_instance_of(Enliterator::Heartbeat).to receive(:execute_async!).and_return(Thread.new {})

      post "/enliterator/heartbeat/beat", params: { budget: 999_999_999 }
      expect(Enliterator::Heartbeat.order(:id).last.budget_tokens)
        .to eq(Enliterator.configuration.heartbeat_budget_tokens)

      post "/enliterator/heartbeat/beat", params: { budget: "", force: "1" }
      expect(Enliterator::Heartbeat.order(:id).last.budget_tokens)
        .to eq(Enliterator.configuration.heartbeat_budget_tokens)
    end

    it "a blocked beat flashes the open cycle and creates nothing; force proceeds" do
      blocking = Enliterator::Heartbeat.create!(started_at: 5.minutes.ago, mode: "sync", budget_tokens: 1)
      allow_any_instance_of(Enliterator::Heartbeat).to receive(:execute_async!).and_return(Thread.new {})

      post "/enliterator/heartbeat/beat"
      expect(Enliterator::Heartbeat.count).to eq(1)
      follow_redirect!
      expect(response.body).to include("##{blocking.id} is still open")

      post "/enliterator/heartbeat/beat", params: { force: "1" }
      expect(Enliterator::Heartbeat.count).to eq(2)
    end
  end

  describe "GET /enliterator/heartbeat/pulse/:id" do
    let(:widget) { Widget.create!(title: "T", body: "b") }
    let(:row) do
      Enliterator::Heartbeat.create!(started_at: 10.minutes.ago, mode: "sync", budget_tokens: 10_000,
                                     planned: { "counts" => { "frontier" => 3 } })
    end

    def stamp_visit!(facet:, status: "succeeded", applied: true, tier: "cheap", tokens: 100, at: 1.minute.ago)
      widget.enliterator_visits.create!(
        facet: facet, status: status, applied: applied, tier: tier, reason: "frontier",
        heartbeat: row, tokens: { "total" => tokens },
        created_at: at, updated_at: at, started_at: at
      )
    end

    it "counts items as DISTINCT record+facet+context tuples — escalation pairs and failures don't inflate" do
      stamp_visit!(facet: "summary", tier: "cheap", applied: false)   # escalated junior…
      stamp_visit!(facet: "summary", tier: "quality")                 # …same item, senior
      stamp_visit!(facet: "connections", status: "failed", applied: false)

      get "/enliterator/heartbeat/pulse/#{row.id}"
      p = JSON.parse(response.body)
      expect(p["items_done"]).to eq(2)                  # summary (once) + connections
      expect(p["done_by_reason"]).to eq({ "frontier" => 2 })
      expect(p["tokens_total"]).to eq(300)
      expect(p["last_visits"].size).to eq(3)
      expect(p["last_visits"].map { |v| v["tier"] }).to include("quality", "cheap")
      expect(p["finished"]).to be(false)
      expect(p).not_to have_key("executed")
    end

    it "flags a stalled cycle (no visit activity for minutes)" do
      row.update_columns(started_at: 20.minutes.ago)
      stamp_visit!(facet: "summary", at: 10.minutes.ago)
      get "/enliterator/heartbeat/pulse/#{row.id}"
      expect(JSON.parse(response.body)["stalled"]).to be(true)
    end

    it "a finished row carries the full books: executed, warnings, considerer" do
      row.update!(finished_at: Time.current,
                  executed: { "frontier" => { "succeeded" => 3 } },
                  warnings: [ "budget reached on actuals after 3 item(s)" ],
                  considerer: { "root" => { "considered" => 2 } })
      get "/enliterator/heartbeat/pulse/#{row.id}"
      p = JSON.parse(response.body)
      expect(p["finished"]).to be(true)
      expect(p["executed"]).to include("frontier")
      expect(p["warnings"].join).to include("budget reached")
      expect(p["considerer"]).to include("root")
    end
  end
end
