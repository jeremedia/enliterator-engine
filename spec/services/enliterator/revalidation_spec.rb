# frozen_string_literal: true

require "rails_helper"

# v0.61 — the revalidation DRAIN. A record is "revalidated" for a (facet, context)
# once it has a succeeded applied Visit with reason "revalidate"; the target set is
# the anti-join (tended by anything else, incl. a NULL/legacy reason) and progress is
# a visit query. No column — the revalidate Visit row is the mark.
RSpec.describe "Enliterator::Revalidation (v0.61)" do
  let(:w1) { Widget.create!(title: "A", body: "a") }
  let(:w2) { Widget.create!(title: "B", body: "b") }
  let(:w3) { Widget.create!(title: "C", body: "c") }

  def visit!(record, facet: "summary", reason: nil, context: nil, status: "succeeded", applied: true)
    record.enliterator_visits.create!(
      facet: facet, context: context, status: status, applied: applied, reason: reason,
      tier: "cheap", tokens: { "total" => 1 }, started_at: Time.current, finished_at: Time.current
    )
  end

  describe ".targets — the un-revalidated set" do
    it "includes records tended by a non-revalidate (or NULL) reason; excludes revalidated ones" do
      visit!(w1, reason: nil)                                     # legacy/sedimented → candidate
      visit!(w2, reason: "source_change")                        # candidate
      visit!(w3, reason: nil); visit!(w3, reason: "revalidate")  # drained → excluded

      expect(Enliterator::Revalidation.targets(facet: "summary"))
        .to contain_exactly([ "Widget", w1.id.to_s ], [ "Widget", w2.id.to_s ])
    end

    it "ignores other facets, failed, and unapplied visits" do
      visit!(w1, reason: nil, facet: "other")
      visit!(w2, reason: nil, status: "failed")
      visit!(w3, reason: nil, applied: false)

      expect(Enliterator::Revalidation.targets(facet: "summary")).to be_empty
    end
  end

  describe ".progress — the drain gauge" do
    it "counts total tended vs revalidated" do
      visit!(w1, reason: nil)
      visit!(w2, reason: nil); visit!(w2, reason: "revalidate")

      expect(Enliterator::Revalidation.progress(facet: "summary"))
        .to eq(total: 2, revalidated: 1, remaining: 1)
    end
  end

  describe ".run — enqueues a revalidate re-tend for the un-revalidated" do
    it "enqueues TendingVisitJob(reason: 'revalidate') per target, honoring LIMIT, returning the count" do
      visit!(w1, reason: nil); visit!(w2, reason: nil)
      allow(Enliterator::TendingVisitJob).to receive(:perform_later)

      expect(Enliterator::Revalidation.run(facet: "summary", limit: 1)).to eq(1)
      expect(Enliterator::TendingVisitJob).to have_received(:perform_later)
        .with(anything, "summary", nil, reason: "revalidate").once
    end

    it "enqueues nothing when the set is already fully drained" do
      visit!(w1, reason: nil); visit!(w1, reason: "revalidate")
      allow(Enliterator::TendingVisitJob).to receive(:perform_later)

      expect(Enliterator::Revalidation.run(facet: "summary")).to eq(0)
      expect(Enliterator::TendingVisitJob).not_to have_received(:perform_later)
    end
  end

  describe "context scoping (exact context_id)" do
    let(:ctx) { Enliterator::Context.create!(key: "book", name: "Book") }

    it "a context's drain is separate from root's" do
      visit!(w1, reason: nil, context: ctx)
      visit!(w2, reason: nil)                 # root (context nil)

      expect(Enliterator::Revalidation.targets(facet: "summary", context: ctx))
        .to contain_exactly([ "Widget", w1.id.to_s ])
      expect(Enliterator::Revalidation.targets(facet: "summary"))
        .to contain_exactly([ "Widget", w2.id.to_s ])
    end
  end
end
