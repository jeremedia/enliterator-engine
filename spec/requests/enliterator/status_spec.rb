# frozen_string_literal: true

require "rails_helper"

# v0.6 status browser. Mounted at /enliterator in the dummy host.
RSpec.describe "Enliterator status browser", type: :request do
  let(:widget) { Widget.create!(title: "Acme", body: "a body worth tending") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap", "quality" ]
      end
    end
    widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, model: "cheap", tier: "cheap")
    widget.enliterator_claims.create!(key: "summary", value: "An account of Acme.", status: "draft")
  end

  it "GET /enliterator/ (root) renders the status overview" do
    get "/enliterator/"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Status").and include("summary")
  end

  it "GET /enliterator/status renders facet cards + the health table" do
    get "/enliterator/status"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Facets").and include("Tending health")
  end

  it "highlights a null adapter in the health table (the smoke alarm)" do
    widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, model: "null", tier: "cheap")
    get "/enliterator/status"
    expect(response.body).to include("null adapter ran")
  end

  it "GET /enliterator/status/Widget/:id renders the record's claims + visits" do
    get "/enliterator/status/Widget/#{widget.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("An account of Acme.").and include("Live claims")
  end

  it "404s an unknown record id" do
    get "/enliterator/status/Widget/0"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("No tended record")
  end

  it "404s (allow-list) a class that isn't a registered tendable model" do
    get "/enliterator/status/String/1"
    expect(response).to have_http_status(:not_found)
  end

  describe "Understanding over time (v0.14 trajectory surface)" do
    it "is ABSENT with a single applied visit per facet" do
      get "/enliterator/status/Widget/#{widget.id}"
      expect(response.body).not_to include("Understanding over time")
    end

    it "renders the timeline with a highlighted changed cell once a facet has 2 applied visits" do
      t1, t2 = 2.hours.ago, 1.hour.ago
      v1 = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                             tier: "cheap", confidence: 0.8,
                                             reconciliation: { "added" => [ "summary" ], "updated" => [], "deleted" => [], "noop" => [] },
                                             created_at: t1, updated_at: t1)
      old = widget.enliterator_claims.create!(key: "summary", value: "shallow first take",
                                              visit: v1, status: "draft", created_at: t1, updated_at: t1)
      v2 = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                             tier: "cheap", confidence: 0.92,
                                             reconciliation: { "added" => [], "updated" => [ "summary" ], "deleted" => [], "noop" => [] },
                                             created_at: t2, updated_at: t2)
      fresh = widget.enliterator_claims.create!(key: "summary", value: "a deeper synthesis citing neighbors",
                                                visit: v2, status: "draft", created_at: t2, updated_at: t2)
      old.supersede!(fresh)

      get "/enliterator/status/Widget/#{widget.id}"
      expect(response.body).to include("Understanding over time")
        .and include("shallow first take")
        .and include("a deeper synthesis citing neighbors")
      expect(response.body).to include('style="background:var(--accent-soft)"')   # the changed cell
    end
  end
  describe "Heartbeat preview (v0.15 — adoption-gated)" do
    it "is ABSENT until a cycle has ever run (byte-identical page, no planner queries)" do
      get "/enliterator/status"
      expect(response.body).not_to include("next cycle:")   # the nav link exists (v0.16); the preview section must not
    end

    it "renders the PREPARED next-cycle counts, horizon, and the last cycle once adopted (v0.20: from the ledger, never a live census)" do
      hb = Enliterator::Heartbeat.create!(
        started_at: 1.day.ago, finished_at: 1.day.ago + 10.minutes, mode: "sync",
        budget_tokens: 30_000,
        planned: { "counts" => { "frontier" => 4 }, "est_total" => 2_000,
                   "frontier_total" => 9, "horizon_cycles" => 1,
                   "lanes" => { "root/summary" => { "frontier" => 4 } }, "warnings" => [] },
        executed: { "frontier" => { "succeeded" => 4, "failed" => 0, "skipped" => 0, "enqueued" => 0 } },
        tokens_spent: { "input" => 200, "output" => 200, "total" => 400 }
      )
      Widget.create!(title: "untended", body: "b")   # on the frontier — must NOT be censused

      expect(Enliterator::Heartbeat).not_to receive(:plan)   # the page reads the ledger
      get "/enliterator/status"
      expect(response.body).to include("Heartbeat")
        .and include("next cycle:")
        .and include("frontier:")          # the horizon line
        .and include("plan as of cycle ##{hb.id}")
        .and include("last cycle:")
        .and include("400 tokens")
    end
  end
  describe "Condition — the conservation report (v0.17, adoption-gated)" do
    it "is ABSENT until a survey has ever run" do
      get "/enliterator/status"
      expect(response.body).not_to include("conservation report")
    end

    it "renders coverage, piles with remediation + treatment, and the residue" do
      Enliterator::Condition.register(:legibility, gates_tending: true) do |r|
        { ok: r.body.present?, code: "no_text", note: "no usable text",
          remediation: "upload the PDF" }
      end
      dead = Widget.create!(title: "Dead Record", body: nil)
      Enliterator::Condition.survey_batch!([ dead, widget ])
      Enliterator::Treatment.create!(signature: "legibility:no_text", rung: 1,
                                     diagnosis: "These records carry no text.",
                                     treatment: "Per the stated remediation: upload PDFs.",
                                     confidence: 0.9, last_seen_count: 1,
                                     sample: [ [ "Widget", dead.id.to_s, "Dead Record" ] ])

      get "/enliterator/status"
      expect(response.body).to include("conservation report")
        .and include("legibility:no_text")
        .and include("untendable")
        .and include("upload the PDF")                          # the probe's remediation
        .and include("These records carry no text.")            # the conservator's diagnosis
        .and include("Dead Record")                             # a sample title
    end
  end
end
