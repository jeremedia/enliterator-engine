# frozen_string_literal: true

require "rails_helper"

# v0.14 — the longitudinal read: reconstruct a record's claim-state at any past
# visit from the provenance the loop already writes, diff consecutive states,
# flag churn, and roll up compounding metrics per pass.
RSpec.describe Enliterator::Trajectory do
  let(:widget) { Widget.create!(title: "T", body: "b") }

  # A succeeded+applied visit at a controlled time.
  def visit!(facet: "summary", at:, confidence: 0.9, recon: {})
    widget.enliterator_visits.create!(
      facet: facet, status: "succeeded", applied: true, tier: "cheap",
      confidence: confidence, reconciliation: recon,
      created_at: at, updated_at: at, started_at: at, finished_at: at
    )
  end

  def claim!(key:, value:, visit: nil, at:, status: "draft", locked: false)
    widget.enliterator_claims.create!(
      key: key, value: value, visit: visit, status: status, locked: locked,
      created_at: at, updated_at: at
    )
  end

  describe ".state_at (reconstruction)" do
    let(:t1) { 3.hours.ago }
    let(:t2) { 2.hours.ago }
    let(:t3) { 1.hour.ago }

    it "an ADDed claim is live from its creation onward" do
      claim!(key: "summary", value: "v1", at: t1)
      expect(described_class.state_at(widget, t1 - 1.minute)).to be_empty
      expect(described_class.state_at(widget, t1 + 1.minute).map(&:key)).to eq([ "summary" ])
    end

    it "an UPDATE chain flips state exactly at the superseding claim's creation" do
      old = claim!(key: "summary", value: "v1", at: t1)
      fresh = claim!(key: "summary", value: "v2 — deeper", at: t2)
      old.supersede!(fresh)

      at_t1 = described_class.state_at(widget, t1 + 1.minute)
      expect(at_t1.map(&:id)).to eq([ old.id ])          # before the update: v1 live

      at_t2 = described_class.state_at(widget, t2 + 1.minute)
      expect(at_t2.map(&:id)).to eq([ fresh.id ])         # after: only v2
    end

    it "a DELETE tombstone (superseded, no successor) disappears at its updated_at" do
      c = claim!(key: "stale", value: "x", at: t1)
      c.update_columns(status: "superseded", updated_at: t3)   # the loop's DELETE, at t3

      expect(described_class.state_at(widget, t2).map(&:key)).to eq([ "stale" ])  # before delete
      expect(described_class.state_at(widget, t3 + 1.minute)).to be_empty          # after
    end

    it "locked host claims (visit nil) follow the same rule" do
      claim!(key: "publication_year", value: 2022, at: t1, status: "verified", locked: true)
      expect(described_class.state_at(widget, t2).map(&:key)).to eq([ "publication_year" ])
    end

    it "scopes by context (own + ancestors + root NULL)" do
      root = Enliterator::Context.create!(key: "hsdl", name: "HSDL")
      eo   = Enliterator::Context.create!(key: "executive-orders", name: "EOs", parent: root)
      sib  = Enliterator::Context.create!(key: "crs-reports", name: "CRS", parent: root)
      claim!(key: "root_claim", value: "r", at: t1)
      widget.enliterator_claims.create!(key: "eo_claim", value: "e", status: "draft",
                                        context: eo, created_at: t1, updated_at: t1)
      widget.enliterator_claims.create!(key: "sib_claim", value: "s", status: "draft",
                                        context: sib, created_at: t1, updated_at: t1)

      keys = described_class.state_at(widget, t2, context: eo).map(&:key)
      expect(keys).to contain_exactly("root_claim", "eo_claim")   # never the sibling's
    end
  end

  describe ".state_after (post-reconcile state — the instrument-calibration fix)" do
    it "includes the visit's OWN writes even though claims land after the visit row's created_at" do
      t1 = 3.hours.ago
      v1 = visit!(at: t1, recon: {})
      # The real-data condition: the claim is created SECONDS after the Visit row
      # (the row opens the pass; reconcile writes at the end).
      claim!(key: "summary", value: "written during v1", visit: v1, at: t1 + 8.seconds)

      expect(described_class.state_at(widget, v1)).to be_empty            # before-the-visit semantics
      expect(described_class.state_after(widget, v1).map(&:key)).to eq([ "summary" ])  # what it left behind
    end

    it "bounds at the next applied visit on the facet (the next pass's writes excluded)" do
      t1, t2 = 3.hours.ago, 1.hour.ago
      v1 = visit!(at: t1, recon: {})
      old = claim!(key: "summary", value: "v1 take", visit: v1, at: t1 + 5.seconds)
      v2 = visit!(at: t2, recon: {})
      fresh = claim!(key: "summary", value: "v2 deeper take", visit: v2, at: t2 + 5.seconds)
      old.supersede!(fresh)

      after_v1 = described_class.state_after(widget, v1)
      expect(after_v1.map(&:id)).to eq([ old.id ])      # v2's supersession not yet visible
      after_v2 = described_class.state_after(widget, v2)
      expect(after_v2.map(&:id)).to eq([ fresh.id ])
    end
  end

  describe ".for (the per-facet timeline)" do
    let(:t1) { 3.hours.ago }
    let(:t2) { 1.hour.ago }

    it "groups by facet, orders steps, and diffs consecutive states" do
      v1 = visit!(at: t1, recon: { "added" => [ "summary" ], "updated" => [], "deleted" => [], "noop" => [] })
      claim!(key: "summary", value: "first reading of the document", visit: v1, at: t1)

      v2 = visit!(at: t2, confidence: 0.95,
                  recon: { "added" => [ "keywords" ], "updated" => [ "summary" ], "deleted" => [], "noop" => [] })
      old = widget.enliterator_claims.find_by(key: "summary")
      fresh = claim!(key: "summary", value: "a substantially deeper synthesis citing neighbors", visit: v2, at: t2)
      old.supersede!(fresh)
      claim!(key: "keywords", value: "FOIA, AI", visit: v2, at: t2)

      lines = described_class.for(widget)
      expect(lines.size).to eq(1)
      line = lines.first
      expect(line[:facet]).to eq("summary")
      expect(line[:steps].size).to eq(2)

      first, second = line[:steps]
      expect(first[:diff]).to be_nil
      expect(first[:state].keys).to eq([ "summary" ])
      expect(second[:ops][:updated]).to eq([ "summary" ])

      kinds = second[:diff].index_by { |d| d[:key] }
      expect(kinds["summary"][:kind]).to eq(:changed)
      expect(kinds["summary"][:churn]).to be(false)            # genuinely different text
      expect(kinds["keywords"][:kind]).to eq(:added)
    end

    it "flags a near-identical UPDATE as churn" do
      v1 = visit!(at: t1, recon: {})
      claim!(key: "summary", value: "The thesis examines FOIA exemptions in detail.", visit: v1, at: t1)
      v2 = visit!(at: t2, recon: {})
      old = widget.enliterator_claims.find_by(key: "summary")
      fresh = claim!(key: "summary", value: "The thesis examines FOIA exemptions in detail!", visit: v2, at: t2)
      old.supersede!(fresh)

      diff = described_class.for(widget).first[:steps].last[:diff]
      change = diff.find { |d| d[:key] == "summary" }
      expect(change[:churn]).to be(true)
      expect(change[:similarity]).to be > described_class::CHURN_THRESHOLD
    end

    it "keeps facet timelines separate (a claim belongs to its creating visit's facet)" do
      v1 = visit!(facet: "summary", at: t1, recon: {})
      claim!(key: "summary", value: "x", visit: v1, at: t1)
      v2 = visit!(facet: "authorship", at: t2, recon: {})
      claim!(key: "authored_by", value: "Jane Roe", visit: v2, at: t2)

      lines = described_class.for(widget).index_by { |l| l[:facet] }
      expect(lines["summary"][:steps].last[:state].keys).to eq([ "summary" ])
      expect(lines["authorship"][:steps].last[:state].keys).to eq([ "authored_by" ])
    end
  end

  describe ".compounding_summary (the experiment rollup)" do
    it "aggregates op mix, confidence, and churn per pass index" do
      t1, t2 = 3.hours.ago, 1.hour.ago
      v1 = visit!(at: t1, confidence: 0.8,
                  recon: { "added" => %w[summary], "updated" => [], "deleted" => [], "noop" => [] })
      claim!(key: "summary", value: "first", visit: v1, at: t1)
      v2 = visit!(at: t2, confidence: 0.9,
                  recon: { "added" => [], "updated" => %w[summary], "deleted" => [], "noop" => %w[keywords] })
      old = widget.enliterator_claims.find_by(key: "summary")
      fresh = claim!(key: "summary", value: "second, richer and longer with citations", visit: v2, at: t2)
      old.supersede!(fresh)

      s = described_class.compounding_summary([ widget ])
      expect(s.keys).to eq([ 1, 2 ])
      expect(s[1][:ops][:added]).to eq(1)
      expect(s[1][:mean_confidence]).to eq(0.8)
      expect(s[2][:ops][:updated]).to eq(1)
      expect(s[2][:ops][:noop]).to eq(1)
      expect(s[2][:churn_rate]).to eq(0.0)                 # the update was real
    end
  end
end
