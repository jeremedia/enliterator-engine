# frozen_string_literal: true

require "rails_helper"

# v0.8 — the materialized pressure aggregate. refresh! recomputes per-key pressure
# from the Suggestion proposal log; resurged_count flags proposals that returned
# after a verdict.
RSpec.describe Enliterator::ProposedTerm do
  let(:a) { Widget.create!(title: "A", body: "x") }
  let(:b) { Widget.create!(title: "B", body: "y") }

  def suggest!(record:, key:, stream: "summary", status: "pending", created_at: nil, updated_at: nil)
    attrs = { tendable: record, stream: stream, proposed_key: key, rationale: "r", status: status }
    attrs[:created_at] = created_at if created_at
    attrs[:updated_at] = updated_at if updated_at
    Enliterator::Suggestion.create!(**attrs)
  end

  describe ".refresh!" do
    it "aggregates pressure (total proposals), distinct records, and by_stream" do
      suggest!(record: a, key: "keywords")
      suggest!(record: b, key: "keywords")
      suggest!(record: a, key: "keywords", stream: "significance") # same record, 2nd stream
      described_class.refresh!

      t = described_class.find_by(proposed_key: "keywords")
      expect(t.pressure).to eq(3)            # three proposal rows
      expect(t.distinct_records).to eq(2)    # two distinct records
      expect(t.by_stream).to eq("summary" => 2, "significance" => 1)
    end

    it "is idempotent and preserves a stored recommendation across refreshes" do
      suggest!(record: a, key: "author")
      described_class.refresh!
      described_class.find_by(proposed_key: "author")
        .record_recommendation!(decision: "map", map_to: "authored_by", rationale: "synonym", confidence: 0.9)

      suggest!(record: b, key: "author") # new pressure
      described_class.refresh!

      t = described_class.find_by(proposed_key: "author")
      expect(t.pressure).to eq(2)                       # recomputed
      expect(t.recommended_decision).to eq("map")       # preserved
      expect(t.recommended_map_to).to eq("authored_by")
    end

    it "counts resurged proposals — those created after a verdict" do
      # one proposal, rejected at T0; then a NEW pending proposal arrives later
      suggest!(record: a, key: "thematic_focus", status: "rejected",
               created_at: 2.hours.ago, updated_at: 1.hour.ago)
      suggest!(record: b, key: "thematic_focus", status: "pending", created_at: 10.minutes.ago)
      described_class.refresh!

      t = described_class.find_by(proposed_key: "thematic_focus")
      expect(t.resurged_count).to eq(1)
      expect(described_class.resurged).to include(t)
    end

    it "scopes: open (has pending), by_pressure (ranked)" do
      suggest!(record: a, key: "high");  suggest!(record: b, key: "high")
      suggest!(record: a, key: "low")
      suggest!(record: a, key: "done", status: "approved") # no pending → not open
      described_class.refresh!

      expect(described_class.by_pressure.first.proposed_key).to eq("high")
      open_keys = described_class.open.pluck(:proposed_key)
      expect(open_keys).to include("high", "low")
      expect(open_keys).not_to include("done")
    end
  end
end
