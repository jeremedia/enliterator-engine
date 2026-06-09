# frozen_string_literal: true

require "rails_helper"

# v0.17 — condition meets the heartbeat: the untendable gate on every
# candidate queue, the per-cycle survey phase, and the execution-time gate.
RSpec.describe "Enliterator::Heartbeat × Condition (v0.17)" do
  let(:root) { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
  let(:crs)  { Enliterator::Context.create!(key: "crs-reports", name: "CRS", parent: root) }

  def configure_policy!
    Enliterator.configure do |c|
      c.tending_facets = []
      c.staffing = Enliterator::Staffing::Policy.new do
        context "crs-reports" do
          facet :policy_analysis, tier: "cheap", terms: { issue_for_congress: "The issue." }
        end
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
  end

  def widget!(title = "w", body: "text")
    w = Widget.create!(title: title, body: body)
    w.update_columns(created_at: 90.days.ago, updated_at: 90.days.ago)
    w.place_in_context!(crs)
    w
  end

  def visit!(record, at: 2.days.ago, tokens: { "total" => 100 })
    record.enliterator_visits.create!(
      facet: "policy_analysis", context: crs, status: "succeeded", applied: true, tier: "cheap",
      tokens: tokens, created_at: at, updated_at: at, started_at: at, finished_at: at + 5.seconds
    )
  end

  def register_legibility!
    Enliterator::Condition.register(:legibility, gates_tending: true) do |r|
      { ok: r.body.present?, code: "no_text", note: "no usable text" }
    end
  end

  before { configure_policy! }

  describe "the untendable gate across the queues" do
    it "frontier excludes untendable; degraded and never-surveyed pass; the plan says so" do
      register_legibility!
      blank    = widget!("blank", body: nil)
      degraded = widget!("degraded")
      never    = widget!("never-surveyed")
      Enliterator::Condition.survey_batch!([ blank, degraded ])
      # degrade the second via a non-gating failure
      Enliterator::Condition.register(:availability) { |r| { ok: r.title != "degraded", code: "url_dead" } }
      Enliterator::Condition.survey_batch!([ blank, degraded ])

      plan = Enliterator::Heartbeat.plan
      ids = plan.items.select { |i| i.reason == "frontier" }.map(&:tendable_id)
      expect(ids).to include(degraded.id.to_s, never.id.to_s)
      expect(ids).not_to include(blank.id.to_s)
      expect(plan.warnings.join).to include("1 record(s) untendable — excluded from every queue")
    end

    it "source_change is gated too — a host status-flip that bumps updated_at cannot re-tend a condemned record" do
      register_legibility!
      condemned = widget!("condemned")
      visit!(condemned, at: 10.days.ago)               # previously tended
      condemned.update_columns(body: nil, updated_at: 1.hour.ago)   # source died; row touched
      Enliterator::Condition.survey!(condemned)        # survey condemns it

      plan = Enliterator::Heartbeat.plan
      expect(plan.items.select { |i| i.reason == "source_change" }.map(&:tendable_id))
        .not_to include(condemned.id.to_s)
    end

    it "the sweep is gated (stale + untendable stays excluded)" do
      Enliterator.configuration.stale_after = 30.days
      register_legibility!
      stale_dead = widget!("stale-dead", body: nil)
      visit!(stale_dead, at: 60.days.ago)
      Enliterator::Condition.survey!(stale_dead)

      plan = Enliterator::Heartbeat.plan
      expect(plan.items.map(&:reason)).not_to include("sweep")
    end

    it "non-adopters keep gate-free SQL (no condition rows ⇒ cond_pred renders empty)" do
      planner = Enliterator::Heartbeat::Planner.new
      expect(planner.send(:cond_pred, "x", "y")).to eq("")
      register_legibility!
      Enliterator::Condition.survey!(widget!("adopter"))
      planner2 = Enliterator::Heartbeat::Planner.new
      expect(planner2.send(:cond_pred, "x", "y")).to include("NOT EXISTS")
    end
  end

  describe "the survey phase in beat!" do
    class CondBeatStub
      Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
      def model_id = "model-cheap"
      def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
        Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {},
                   tokens: { "total" => 100 })
      end
    end

    it "shelf-reads before tending, records the outcome on the ledger, and gates condemned planned items" do
      register_legibility!
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(CondBeatStub.new)
      readable = widget!("readable")
      visit!(readable, at: 40.days.ago)   # token history for estimation
      blank = widget!("blank", body: nil) # on the frontier at plan time (never surveyed)

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)

      expect(row.survey["surveyed"]).to be >= 2
      expect(row.survey["untendable"]).to eq(1)
      # blank was PLANNED (never surveyed at open!) but the cycle's own survey
      # condemned it before execution — skipped, not tended.
      expect(row.executed.dig("frontier", "skipped")).to eq(1)
      expect(blank.enliterator_visits.count).to eq(0)
      expect(row.survey["duration_ms"]).to be_a(Integer)
    end

    it "is absent (and harmless) when no probes are registered" do
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(CondBeatStub.new)
      w = widget!("w")
      visit!(w, at: 40.days.ago)

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(row.survey).to eq({})
    end

    it "a survey failure warns and the tending cycle continues" do
      register_legibility!
      allow(Enliterator::Condition).to receive(:survey_due).and_raise("survey exploded")
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(CondBeatStub.new)
      w = widget!("w")
      visit!(w, at: 40.days.ago)

      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(row.warnings.join).to include("survey phase failed")
      expect(row.error).to be_nil
      expect(row).to be_finished
    end
  end
end
