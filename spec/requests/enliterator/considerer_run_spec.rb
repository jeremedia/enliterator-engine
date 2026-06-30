# frozen_string_literal: true

require "rails_helper"

# ConsidererRun pulse endpoint + off-path (no active run) byte-identical contract.
RSpec.describe "Enliterator ConsidererRun pulse + suggestions off-path", type: :request do
  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
    end
  end

  # ── GET /enliterator/suggestions/consider/pulse/:id ──────────────────────────

  describe "GET /enliterator/suggestions/consider/pulse/:id" do
    it "returns the JSON payload for a running run" do
      run = Enliterator::ConsidererRun.create!(
        status: "running", started_at: 2.minutes.ago,
        done_count: 5, planned_count: 20, phase: "considering"
      )
      run.update_columns(pulse_at: 30.seconds.ago)

      get "/enliterator/suggestions/consider/pulse/#{run.id}"
      expect(response).to have_http_status(:ok)
      payload = JSON.parse(response.body)

      expect(payload["id"]).to eq(run.id)
      expect(payload["status"]).to eq("running")
      expect(payload["phase"]).to eq("considering")
      expect(payload["done_count"]).to eq(5)
      expect(payload["planned_count"]).to eq(20)
      expect(payload["finished"]).to be(false)
      expect(payload["error"]).to be_nil
      expect(payload["summary"]).to be_nil   # only present when finished
    end

    it "returns the full payload including summary for a finished run" do
      run = Enliterator::ConsidererRun.create!(
        status: "finished", started_at: 5.minutes.ago, finished_at: 1.minute.ago,
        done_count: 20, planned_count: 20, phase: "done",
        summary: { "considered" => 20, "auto_mapped" => 2, "auto_rejected" => 3,
                   "approves_recommended" => 1, "held" => 0 }
      )
      run.update_columns(pulse_at: 1.minute.ago)

      get "/enliterator/suggestions/consider/pulse/#{run.id}"
      expect(response).to have_http_status(:ok)
      payload = JSON.parse(response.body)

      expect(payload["finished"]).to be(true)
      expect(payload["summary"]).to include("considered" => 20, "auto_mapped" => 2)
      expect(payload["status"]).to eq("finished")
    end

    it "sets stalled=true when pulse_at is older than STALL_AFTER" do
      run = Enliterator::ConsidererRun.create!(
        status: "running", started_at: 20.minutes.ago, done_count: 3, planned_count: 10
      )
      run.update_columns(pulse_at: (Enliterator::ConsidererRun::STALL_AFTER + 2.minutes).ago)

      get "/enliterator/suggestions/consider/pulse/#{run.id}"
      expect(JSON.parse(response.body)["stalled"]).to be(true)
    end

    it "sets stalled=false when pulse_at is recent" do
      run = Enliterator::ConsidererRun.create!(
        status: "running", started_at: 2.minutes.ago, done_count: 3, planned_count: 10
      )
      run.update_columns(pulse_at: 30.seconds.ago)

      get "/enliterator/suggestions/consider/pulse/#{run.id}"
      expect(JSON.parse(response.body)["stalled"]).to be(false)
    end

    it "reaps an orphaned row on the poll and returns finished=true" do
      run = Enliterator::ConsidererRun.create!(
        status: "running", started_at: 30.minutes.ago, done_count: 5, planned_count: 10
      )
      run.update_columns(pulse_at: (Enliterator::ConsidererRun::REAP_AFTER + 5.minutes).ago)

      get "/enliterator/suggestions/consider/pulse/#{run.id}"
      payload = JSON.parse(response.body)
      expect(payload["finished"]).to be(true)
      expect(payload["status"]).to eq("reaped")
      expect(run.reload.finished_at).to be_present
    end
  end

  # ── POST /enliterator/suggestions/consider (async, no longer blocks) ─────────

  describe "POST /enliterator/suggestions/consider" do
    it "creates a ConsidererRun and redirects with a notice, without running inline" do
      allow_any_instance_of(Enliterator::ConsidererRun).to receive(:execute_async!).and_return(Thread.new {})

      post "/enliterator/suggestions/consider"
      expect(response).to redirect_to("/enliterator/suggestions")

      run = Enliterator::ConsidererRun.order(:id).last
      expect(run).not_to be_nil
      expect(run.status).to eq("running")

      follow_redirect!
      expect(response.body).to include("Considering").and include("run ##{run.id}")
    end

    it "flashes alert and creates no row when an Overlap is raised" do
      Enliterator::ConsidererRun.create!(status: "running", started_at: 1.hour.ago)

      post "/enliterator/suggestions/consider"
      expect(response).to redirect_to("/enliterator/suggestions")
      expect(Enliterator::ConsidererRun.count).to eq(1)   # no new row

      follow_redirect!
      expect(response.body).to include("still open")
    end
  end

  # ── Off-path: GET /enliterator/suggestions with NO active run ────────────────
  # When no ConsidererRun is unfinished the page MUST be byte-identical to what
  # it was before this feature. The monitor markup and the poll JS must be absent.

  describe "GET /enliterator/suggestions — off-path (no active run)" do
    it "renders the page without any monitor markup or poll script" do
      get "/enliterator/suggestions"
      expect(response).to have_http_status(:ok)

      # The CSS (.pulse-track etc.) lives unconditionally in the <style> block, as on the
      # heartbeat page — that's fine (inert without the markup). Only the DOM and JS that
      # drive the live monitor must be absent when there is no active run.
      expect(response.body).not_to include("consider_pulse")
      expect(response.body).not_to include("pulseUrl")
      expect(response.body).not_to include('id="monitor"')
      expect(response.body).not_to include("function pollOnce()")
    end

    it "renders the consider button as usual when no run is active" do
      get "/enliterator/suggestions"
      expect(response.body).to include("Consider all requests")
    end
  end
end
