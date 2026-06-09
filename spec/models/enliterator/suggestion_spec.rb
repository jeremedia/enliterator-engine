# frozen_string_literal: true

require "rails_helper"

# v0.3 §3 — the governed suggestion: a model's sanctioned proposal to add a claim
# key to a facet's controlled vocabulary. The model records bio (provenance +
# rationale); a human renders a verdict (approve/map/reject); and #gaps aggregates
# open proposals into a demand-ranked report so the vocabulary can be tended.
RSpec.describe Enliterator::Suggestion do
  let(:widget_a) { Widget.create!(title: "A", body: "first") }
  let(:widget_b) { Widget.create!(title: "B", body: "second") }
  let(:widget_c) { Widget.create!(title: "C", body: "third") }

  def suggest!(record:, key:, rationale: "needed", example: nil, status: "pending")
    attrs = {
      tendable:     record,
      facet:       "metadata",
      proposed_key: key,
      rationale:    rationale,
      status:       status
    }
    attrs[:example_value] = example unless example.nil?
    described_class.create!(**attrs)
  end

  describe ".gaps — demand-ranked aggregation of open proposals" do
    before do
      # "institution" requested across THREE distinct records.
      suggest!(record: widget_a, key: "institution", rationale: "first ask", example: { "name" => "NPS" })
      suggest!(record: widget_b, key: "institution", rationale: "second ask")
      suggest!(record: widget_c, key: "institution", rationale: "third ask")
      # "doi" requested by ONE record.
      suggest!(record: widget_a, key: "doi", rationale: "for citation")
      # A REJECTED proposal must NOT count toward the gap report.
      suggest!(record: widget_b, key: "doi", rationale: "dup", status: "rejected")
    end

    it "ranks proposed keys by distinct-tendable demand, descending" do
      gaps = described_class.gaps
      keys = gaps.map { |g| g[:proposed_key] }
      expect(keys).to eq(%w[institution doi])
    end

    it "counts DISTINCT tendables, ignoring non-pending proposals" do
      gaps = described_class.gaps.index_by { |g| g[:proposed_key] }
      expect(gaps["institution"][:count]).to eq(3)
      # doi has one pending (widget_a) and one rejected (widget_b) — only the
      # pending one counts.
      expect(gaps["doi"][:count]).to eq(1)
    end

    it "carries a sample rationale and example for context" do
      gaps = described_class.gaps.index_by { |g| g[:proposed_key] }
      inst = gaps["institution"]
      expect(inst[:sample_rationale]).to be_present
      expect(inst[:sample_example]).to eq("name" => "NPS")
    end

    it "can be narrowed to a single facet" do
      # A proposal on a different facet must not appear when scoped.
      described_class.create!(
        tendable: widget_a, facet: "other", proposed_key: "tag", rationale: "x", status: "pending"
      )
      keys = described_class.gaps(facet: "metadata").map { |g| g[:proposed_key] }
      expect(keys).to contain_exactly("institution", "doi")
      expect(keys).not_to include("tag")
    end
  end

  describe "status setters (the human's governance verdict)" do
    let(:suggestion) { suggest!(record: widget_a, key: "institution") }

    it "#approve! sets status approved and records the note" do
      suggestion.approve!(note: "good catch")
      suggestion.reload
      expect(suggestion.status).to eq("approved")
      expect(suggestion.review_note).to eq("good catch")
    end

    it "#map! sets status mapped (a synonym of an existing key)" do
      suggestion.map!(note: "== author")
      suggestion.reload
      expect(suggestion.status).to eq("mapped")
      expect(suggestion.review_note).to eq("== author")
    end

    it "#reject! sets status rejected" do
      suggestion.reject!(note: "not needed")
      suggestion.reload
      expect(suggestion.status).to eq("rejected")
      expect(suggestion.review_note).to eq("not needed")
    end

    it "removes a now-resolved proposal from the pending scope and gap report" do
      suggestion.reject!(note: "no")
      expect(described_class.pending).to be_empty
      expect(described_class.gaps).to be_empty
    end
  end

  describe "associations" do
    it "belongs to a polymorphic tendable" do
      s = suggest!(record: widget_a, key: "institution")
      expect(s.tendable).to eq(widget_a)
    end

    it "optionally belongs to a visit (nil is allowed)" do
      s = suggest!(record: widget_a, key: "institution")
      expect(s.visit).to be_nil
    end
  end

  describe "batch verdicts + contract diff (v0.7)" do
    before do
      suggest!(record: widget_a, key: "keywords", rationale: "kw")
      suggest!(record: widget_b, key: "keywords", rationale: "kw2")
      suggest!(record: widget_a, key: "author",   rationale: "syn")
      # a NON-pending row for keywords must be untouched by a batch verdict
      suggest!(record: widget_c, key: "keywords", rationale: "old", status: "rejected")
    end

    it ".approve_key! approves only PENDING rows for the key, returns the count" do
      expect(described_class.approve_key!("keywords", note: "real gap")).to eq(2)
      expect(described_class.where(proposed_key: "keywords", status: "approved").count).to eq(2)
      expect(described_class.where(proposed_key: "keywords", status: "rejected").count).to eq(1) # untouched
    end

    it ".map_key! records the canonical target" do
      described_class.map_key!("author", to: "authored_by", note: "synonym")
      s = described_class.find_by(proposed_key: "author")
      expect(s.status).to eq("mapped")
      expect(s.mapped_to).to eq("authored_by")
    end

    it ".reject_key! rejects pending rows" do
      expect(described_class.reject_key!("keywords")).to eq(2)
    end

    it ".contract_additions groups approved keys by facet" do
      described_class.approve_key!("keywords")
      described_class.approve_key!("author")
      expect(described_class.contract_additions).to eq("metadata" => %w[author keywords])
    end

    it ".synonyms lists proposed -> mapped_to" do
      described_class.map_key!("author", to: "authored_by")
      expect(described_class.synonyms).to contain_exactly(
        { facet: "metadata", proposed_key: "author", mapped_to: "authored_by" }
      )
    end

    it "#map!(to:) records mapped_to on a single row" do
      s = suggest!(record: widget_b, key: "publication_date")
      s.map!(to: "publication_year", note: "more granular")
      s.reload
      expect(s.status).to eq("mapped")
      expect(s.mapped_to).to eq("publication_year")
    end
  end
end
