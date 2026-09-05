# frozen_string_literal: true

require "rails_helper"

# v0.23 — every cycle ends on the ledger. Process death (restart, kill) can't
# be rescued in Ruby; the reaper stamps the orphaned row with an honest
# ending, reconstructing `executed` from the visit record, and a zombie
# thread of the dead cycle stands down instead of double-spending.
RSpec.describe "Enliterator::Heartbeat failure states (v0.23)" do
  def orphan!(phase: "audit", life_ago: 20.minutes, started: 1.hour.ago)
    row = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1_000,
                                         planned: { "counts" => { "frontier" => 3 } },
                                         started_at: started)
    row.update_columns(pulse_at: life_ago.ago, phase: phase)
    row
  end

  def visit!(row, reason: "frontier", status: "succeeded")
    w = Widget.create!(title: "w#{rand(1e9)}", body: "b")
    w.enliterator_visits.create!(facet: "summary", status: status, applied: status == "succeeded",
                                 heartbeat: row, reason: reason,
                                 tokens: { "total" => 100, "input" => 80, "output" => 20 })
  end

  describe ".reap_orphans!" do
    it "stamps a stale row: death phase named, executed reconstructed from visits, finished_at = last life" do
      row = orphan!(phase: "audit", life_ago: 20.minutes)
      2.times { visit!(row, reason: "frontier") }
      visit!(row, reason: "source_change", status: "failed")

      reaped = Enliterator::Heartbeat.reap_orphans!
      expect(reaped.map(&:id)).to eq([ row.id ])

      row.reload
      expect(row.finished_at).to be_within(1.second).of(row.pulse_at)
      expect(row.error).to include("orphaned in phase 'audit'").and include("reconstructed")
      expect(row.executed["frontier"]["succeeded"]).to eq(2)
      expect(row.executed["source_change"]["failed"]).to eq(1)
      expect(row.phase).to be_nil
      expect(row.tokens_spent["total"]).to eq(300)
    end

    it "reaps a pre-v0.23 row (no pulse_at) via updated_at — cycle #12's shape" do
      row = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1_000,
                                           planned: {}, started_at: 2.hours.ago,
                                           considerer: { "root" => { "considered" => 6 } })
      row.update_columns(updated_at: 30.minutes.ago, pulse_at: nil, phase: nil)

      Enliterator::Heartbeat.reap_orphans!
      row.reload
      expect(row.finished_at).to be_present
      expect(row.error).to include("pre-v0.23")
      expect(row.considerer["root"]["considered"]).to eq(6)   # the stamps it DID make survive
    end

    it "leaves a LIVE cycle alone (recent pulse) and finished rows alone" do
      live = orphan!(phase: "work", life_ago: 1.minute)
      done = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 10, planned: {},
                                            started_at: 2.days.ago, finished_at: 2.days.ago + 60)
      expect(Enliterator::Heartbeat.reap_orphans!).to eq([])
      expect(live.reload.finished_at).to be_nil
      expect(done.reload.error).to be_nil
    end

    it "open! buries the dead first — a stale orphan inside the overlap window no longer blocks" do
      orphan!(phase: "considerer", life_ago: 20.minutes, started: 1.hour.ago)
      expect { Enliterator::Heartbeat.open!(budget: 50) }.not_to raise_error
    end

    it "open! still refuses past a LIVE cycle inside the window" do
      orphan!(phase: "work", life_ago: 1.minute, started: 10.minutes.ago)
      expect { Enliterator::Heartbeat.open!(budget: 50) }
        .to raise_error(Enliterator::Heartbeat::Overlap)
    end
  end

  # v0.77 — the visit-level reaper. A heartbeat-less tend (a rake, a runner,
  # a pulse's manual sibling) whose process dies leaves its Visit in `running`
  # forever: no heartbeat row to reap it through, no pulse of its own. Spine
  # carried five such rows for ten weeks. Same rule as the cycle reaper —
  # no sign of life past REAP_AFTER — applied to the visit ledger.
  describe "Enliterator::Visit.reap_orphans! (v0.77)" do
    def running!(started:, heartbeat: nil)
      w = Widget.create!(title: "w#{rand(1e9)}", body: "b")
      v = w.enliterator_visits.create!(facet: "summary", status: "running", applied: true,
                                       heartbeat: heartbeat, started_at: started)
      v.update_columns(created_at: started, updated_at: started)
      v
    end

    it "stamps a heartbeat-less running visit with no sign of life past REAP_AFTER: failed, finished_at = last life, the reason on the row" do
      v = running!(started: 1.hour.ago)

      reaped = Enliterator::Visit.reap_orphans!
      expect(reaped.map(&:id)).to eq([ v.id ])

      v.reload
      expect(v.status).to eq("failed")
      expect(v.finished_at).to be_within(1.second).of(v.started_at)
      expect(v.error).to include("orphaned").and include("reaped")
    end

    it "leaves a young running visit alone, and a running visit under a LIVE cycle alone (the cycle's pulse vouches for it)" do
      young = running!(started: 2.minutes.ago)
      live  = orphan!(phase: "work", life_ago: 1.minute)
      under = running!(started: 1.hour.ago, heartbeat: live)

      expect(Enliterator::Visit.reap_orphans!).to eq([])
      expect(young.reload.status).to eq("running")
      expect(under.reload.status).to eq("running")
    end

    it "reaps a running visit under a FINISHED cycle (its process is gone by definition)" do
      done = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 10, planned: {},
                                            started_at: 2.days.ago, finished_at: 2.days.ago + 60)
      v = running!(started: 1.hour.ago, heartbeat: done)

      expect(Enliterator::Visit.reap_orphans!.map(&:id)).to eq([ v.id ])
      expect(v.reload.status).to eq("failed")
    end

    it "rides the cycle reaper: Heartbeat.reap_orphans! buries orphaned visits too, and still returns only heartbeat rows" do
      row = orphan!(phase: "work", life_ago: 20.minutes)
      v   = running!(started: 1.hour.ago, heartbeat: row)   # the dead cycle's own in-flight visit
      x   = running!(started: 1.hour.ago)                   # a heartbeat-less one

      reaped = Enliterator::Heartbeat.reap_orphans!
      expect(reaped.map(&:id)).to eq([ row.id ])
      expect(v.reload.status).to eq("failed")
      expect(x.reload.status).to eq("failed")
    end

    it "writes nothing when nothing is orphaned" do
      running!(started: 2.minutes.ago)
      expect { Enliterator::Visit.reap_orphans! }.not_to change { Enliterator::Visit.order(:id).pluck(:status, :updated_at) }
    end
  end

  describe "the zombie stand-down" do
    it "a reaped row's own thread raises StoodDown at its next loop check and stamps nothing new" do
      row = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1_000,
                                           planned: { "counts" => {} }, started_at: Time.current)
      plan = Enliterator::Heartbeat::Plan.new(
        budget: 1_000, change_cap: 200, warnings: [], frontier_remaining: {}, horizon_tokens: 0,
        items: [ Enliterator::Heartbeat::Plan::Item.new(
          tendable_type: "Widget", tendable_id: Widget.create!(title: "z", body: "b").id.to_s,
          facet: "summary", context: nil, reason: "frontier", est_tokens: 10
        ) ]
      )
      # Another process reaps the row before the loop's first item.
      row.update_columns(error: "orphaned in phase 'work' — the process ended mid-cycle",
                         finished_at: 5.minutes.ago)

      expect { row.execute!(plan) }.to raise_error(Enliterator::Heartbeat::StoodDown, /standing down/)
      row.reload
      expect(row.error).to include("orphaned")             # the reaper's stamp survives
      expect(row.visits.count).to eq(0)                    # no further spend
    end
  end

  describe "pulse + phase" do
    it "a finished cycle ends with phase cleared and a fresh pulse" do
      Widget.create!(title: "p", body: "b")
      row = Enliterator::Heartbeat.beat!(budget: 5_000)
      expect(row.phase).to be_nil
      expect(row.pulse_at).to be_within(5.seconds).of(row.finished_at)
    end

    it "a WATCHED monitor self-heals: the pulse poll reaps its own orphaned row and serves the ending",
       type: :request do
      row = orphan!(phase: "work", life_ago: 20.minutes)
      visit!(row)

      get "/enliterator/heartbeat/pulse/#{row.id}"
      json = JSON.parse(response.body)
      expect(json["finished"]).to be(true)
      expect(json["error"]).to include("orphaned in phase 'work'")
      expect(row.reload.executed["frontier"]["succeeded"]).to eq(1)
    end

    it "the pulse JSON carries phase, app-zone time labels, and stalls on a stale pulse even at items done",
       type: :request do
      row = orphan!(phase: "audit", life_ago: 6.minutes)   # stale for the banner, fresh for the reaper
      v = visit!(row)

      get "/enliterator/heartbeat/pulse/#{row.id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["phase"]).to eq("audit")
      expect(json["stalled"]).to be(true)                  # all items aside — the pulse is stale
      expect(json["last_visits"].first["at_label"]).to eq(v.created_at.strftime("%H:%M:%S"))
    end
  end

  describe "bounded gateway calls (v0.23)" do
    it "constructs the client with the configured timeout and retries, not the gem's 600s default" do
      Enliterator.configure { |c| c.gateway_timeout = 42; c.gateway_max_retries = 0 }
      adapter = Enliterator::Adapters::LLM::Gateway.new(tier: "cheap", api_key: "k", base_url: "http://x")
      client  = adapter.send(:client)
      expect(client.timeout).to eq(42)
      expect(client.max_retries).to eq(0)
    ensure
      Enliterator.configure { |c| c.gateway_timeout = 180; c.gateway_max_retries = 1 }
    end
  end
end
