# frozen_string_literal: true

require "rails_helper"

# v0.61 + v0.61.1 — the revalidation DRAIN. A record is "revalidated" for a
# (facet, context) once it has a succeeded applied Visit that actually RE-DERIVED
# (re_derived = true) — whether by a deliberate revalidate drain OR an organic
# source_change re-derive. The target set is tended − re-derived; progress is a
# visit query. No table — the Visit's re_derived flag is the mark.
RSpec.describe "Enliterator::Revalidation (v0.61 / v0.61.1)" do
  let(:w1) { Widget.create!(title: "A", body: "a") }
  let(:w2) { Widget.create!(title: "B", body: "b") }
  let(:w3) { Widget.create!(title: "C", body: "c") }

  def visit!(record, facet: "summary", reason: nil, re_derived: nil, context: nil,
             status: "succeeded", applied: true)
    record.enliterator_visits.create!(
      facet: facet, context: context, status: status, applied: applied,
      reason: reason, re_derived: re_derived,
      tier: "cheap", tokens: { "total" => 1 }, started_at: Time.current, finished_at: Time.current
    )
  end

  describe ".targets — the un-revalidated set" do
    it "includes tended records with NO re-derived visit; excludes those already re-derived" do
      visit!(w1, re_derived: false)                                      # tended, not re-derived → target
      visit!(w2, re_derived: nil)                                        # legacy (null) → target
      visit!(w3, re_derived: false)
      visit!(w3, re_derived: true, reason: "revalidate")                # drained → excluded

      expect(Enliterator::Revalidation.targets(facet: "summary"))
        .to contain_exactly([ "Widget", w1.id.to_s ], [ "Widget", w2.id.to_s ])
    end

    it "credits an ORGANIC source_change re-derive too (v0.61.1) — not just a deliberate revalidate" do
      visit!(w1, re_derived: false)                                     # target
      visit!(w2, re_derived: false)
      visit!(w2, re_derived: true, reason: "source_change")            # organically re-derived → excluded

      expect(Enliterator::Revalidation.targets(facet: "summary"))
        .to contain_exactly([ "Widget", w1.id.to_s ])
    end

    it "ignores other facets, failed, and unapplied visits" do
      visit!(w1, re_derived: false, facet: "other")
      visit!(w2, re_derived: false, status: "failed")
      visit!(w3, re_derived: false, applied: false)

      expect(Enliterator::Revalidation.targets(facet: "summary")).to be_empty
    end
  end

  describe ".progress — the drain gauge" do
    it "counts total tended vs re-derived" do
      visit!(w1, re_derived: false)
      visit!(w2, re_derived: false)
      visit!(w2, re_derived: true, reason: "revalidate")

      expect(Enliterator::Revalidation.progress(facet: "summary"))
        .to eq(total: 2, revalidated: 1, remaining: 1)
    end
  end

  describe ".run — enqueues a revalidate re-tend for the un-revalidated" do
    it "enqueues TendingVisitJob(reason: 'revalidate') per target, honoring LIMIT, returning the count" do
      visit!(w1, re_derived: false); visit!(w2, re_derived: false)
      allow(Enliterator::TendingVisitJob).to receive(:perform_later)

      expect(Enliterator::Revalidation.run(facet: "summary", limit: 1)).to eq(1)
      expect(Enliterator::TendingVisitJob).to have_received(:perform_later)
        .with(anything, "summary", nil, reason: "revalidate").once
    end

    it "enqueues nothing when the set is already fully drained" do
      visit!(w1, re_derived: false); visit!(w1, re_derived: true, reason: "revalidate")
      allow(Enliterator::TendingVisitJob).to receive(:perform_later)

      expect(Enliterator::Revalidation.run(facet: "summary")).to eq(0)
      expect(Enliterator::TendingVisitJob).not_to have_received(:perform_later)
    end
  end

  describe "context scoping (exact context_id)" do
    let(:ctx) { Enliterator::Context.create!(key: "book", name: "Book") }

    it "a context's drain is separate from root's" do
      visit!(w1, re_derived: false, context: ctx)
      visit!(w2, re_derived: false)                # root (context nil)

      expect(Enliterator::Revalidation.targets(facet: "summary", context: ctx))
        .to contain_exactly([ "Widget", w1.id.to_s ])
      expect(Enliterator::Revalidation.targets(facet: "summary"))
        .to contain_exactly([ "Widget", w2.id.to_s ])
    end
  end
end
