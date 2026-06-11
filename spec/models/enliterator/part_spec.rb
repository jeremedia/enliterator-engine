# frozen_string_literal: true

require "rails_helper"

# v0.25 — Parts: sections as first-class tendables (analytical entries).
# Engine-internal: full Tendable machinery, but NEVER in the registry, the
# planner's root lanes, the corpus census, or the survey — including via the
# visit-log resurrection path (Visit.host_tendable_types).
RSpec.describe Enliterator::Part do
  include ActiveSupport::Testing::TimeHelpers

  let(:widget) do
    Widget.create!(title: "Continuity Thesis",
                   body: "## Introduction\nWhy continuity matters.\n## Method\nA case study.")
  end

  def sections(*pairs)
    pairs.map { |(h, t)| { heading: h, text: t } }
  end

  describe ".refresh_for!" do
    it "creates parts in order with ordinals, digests, and char ranges" do
      parts = described_class.refresh_for!(widget, sections([ "Intro", "alpha" ], [ "Method", "beta" ]))
      expect(parts.map(&:ordinal)).to eq([ 0, 1 ])
      expect(parts.map(&:heading)).to eq([ "Intro", "Method" ])
      expect(parts.first.content_digest).to eq(Digest::MD5.hexdigest("alpha"))
      expect(parts.first.char_start).to eq(0)
      expect(parts.second.char_start).to eq(5)
    end

    it "updates a changed section IN PLACE — its claims survive, its clock moves (the re-read hook)" do
      part = described_class.refresh_for!(widget, sections([ "Intro", "alpha" ])).first
      claim = part.enliterator_claims.create!(key: "argument", value: "v1", status: "draft")
      was_updated_at = part.reload.updated_at

      travel_to(1.hour.from_now) do
        described_class.refresh_for!(widget, sections([ "Intro", "alpha REVISED" ]))
      end
      part.reload
      expect(part.text).to eq("alpha REVISED")
      expect(part.updated_at).to be > was_updated_at
      expect(claim.reload.tendable).to eq(part)
    end

    it "leaves an unchanged section untouched and destroys vanished trailing sections (claims cascade)" do
      a, b = described_class.refresh_for!(widget, sections([ "Intro", "alpha" ], [ "Method", "beta" ]))
      b.enliterator_claims.create!(key: "argument", value: "doomed", status: "draft")
      untouched_at = a.reload.updated_at

      described_class.refresh_for!(widget, sections([ "Intro", "alpha" ]))
      expect(a.reload.updated_at).to eq(untouched_at)
      expect(described_class.where(record: widget).count).to eq(1)
      expect(Enliterator::Claim.where(tendable_type: "Enliterator::Part", tendable_id: b.id)).to be_empty
    end
  end

  describe ".notebook_for" do
    it "assembles ordered reading notes from live claims only, under their headings" do
      a, b = described_class.refresh_for!(widget, sections([ "Intro", "alpha" ], [ "Method", "beta" ]))
      a.enliterator_claims.create!(key: "argument", value: "Continuity is fragile.", status: "draft")
      a.enliterator_claims.create!(key: "summary", value: "Frames the problem.", status: "draft")
      dead = b.enliterator_claims.create!(key: "method", value: "old", status: "draft")
      dead.update!(status: "superseded")
      b.enliterator_claims.create!(key: "method", value: "Comparative case study.", status: "draft")

      nb = described_class.notebook_for(widget)
      expect(nb).to include("READING NOTES")
      expect(nb.index("## Intro")).to be < nb.index("## Method")
      expect(nb).to include("argument: Continuity is fragile.")
        .and include("method: Comparative case study.")
      expect(nb).not_to include("old")
    end

    it "is empty when no notes exist (the host's front-matter fallback fires)" do
      described_class.refresh_for!(widget, sections([ "Intro", "alpha" ]))
      expect(described_class.notebook_for(widget)).to eq("")
    end
  end

  describe "the engine-internal rule (never a host tendable)" do
    it "is fully Tendable but absent from the registry, and Widget remains present" do
      expect(Enliterator.tendable_models).to include(Widget)
      expect(Enliterator.tendable_models).not_to include(described_class)
      expect(Enliterator.tendable_type?(described_class)).to be(true)   # drill-down pages allowed
      expect(Enliterator.tendable_type?(Widget)).to be(true)
      expect(Enliterator.tendable_type?(String)).to be(false)
      expect(Enliterator.tendable_type?(nil)).to be(false)
    end

    it "is not resurrected from the visit log: tended parts stay out of root lanes and the corpus census" do
      widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      part = described_class.refresh_for!(widget, sections([ "Intro", "alpha" ])).first
      part.enliterator_visits.create!(facet: "analysis", status: "succeeded", applied: true, tier: "cheap")

      expect(Enliterator::Visit.host_tendable_types).to eq([ "Widget" ])
      plan = Enliterator::Heartbeat.plan
      expect(plan.items.map(&:tendable_type)).not_to include("Enliterator::Part")
      corpus = Enliterator::Catalog.new.overview[:stats][:corpus]
      expect(corpus).to eq(Widget.count)   # parts never counted as holdings
    end
  end

  describe "the audit examiner grounds part claims in the part's own text" do
    it "verifies against the section, stamping its digest and length" do
      part  = described_class.refresh_for!(widget, sections([ "Intro", "alpha text" ])).first
      visit = part.enliterator_visits.create!(facet: "analysis", status: "succeeded",
                                              applied: true, tier: "cheap")
      claim = part.enliterator_claims.create!(key: "argument", value: "Alpha.",
                                              status: "draft", visit: visit)

      decide_stub = Class.new do
        def model_id = "stub-examiner"
        def decide(messages:, schema:, tool_name:, tags: [])
          { "verdict" => "supported", "rationale" => "the section says alpha", "confidence" => 0.9 }
        end
      end.new

      audit = Enliterator::Audit::Examiner.new(llm: decide_stub).examine!(claim)
      expect(audit.verdict).to eq("supported")
      expect(audit.source_chars).to eq(part.enliterator_text.length)
      expect(audit.source_digest).to eq(Digest::MD5.hexdigest(part.enliterator_text))
    end
  end
end
