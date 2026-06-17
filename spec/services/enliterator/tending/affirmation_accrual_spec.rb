# frozen_string_literal: true

require "rails_helper"

# Stage 1 (read-time warrant accrual) — the ACCRUAL semantics affirmation rides on.
#
# Affirmation = a reader emits an EXISTING candidate's `proposed_key` (rather than
# coining a synonym). The engine already persists that as another Suggestion row
# (persist_suggestions!, no dedup for unresolved keys), and warrant is the gap
# report's COUNT(DISTINCT tendable). This spec VERIFIES (does not rebuild) that the
# real Visitor loop accrues warrant correctly:
#   - a second DISTINCT record affirming the same key raises that key's warrant,
#   - a same-record re-tend does NOT (warrant = breadth of demand, not raw count),
#   - no synonym is minted by affirmation,
#   - a key resolved in an ANCESTOR context is not offered to a child reader.
# The MODEL's *decision* to affirm (vs synonymize) is a deployment property verified
# live; here we pin the mechanism the candidate block depends on.
RSpec.describe "Enliterator::Tending::Visitor affirmation accrual (stage 1)" do
  # A reader stub that EMITS a suggestion for `proposed_key` (simulating a reader
  # proposing/affirming a candidate). No claims; high confidence (no escalation).
  class AffirmingStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    def initialize(proposed_key:)
      @proposed_key = proposed_key
    end

    def model_id
      "model-cheap"
    end

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, candidates: nil)
      Result.new(
        parsed: {
          "claims"      => [],
          "suggestions" => [
            { "proposed_key" => @proposed_key, "rationale" => "names the #{@proposed_key}" }
          ],
          "confidence"  => 0.95
        },
        raw:    { "tier" => "cheap" },
        tokens: { "input" => 5, "output" => 2, "total" => 7 }
      )
    end
  end

  let(:rec_a)    { Widget.create!(title: "A", body: "names a funder") }
  let(:rec_b)    { Widget.create!(title: "B", body: "names a funder too") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  before do
    policy = Enliterator::Staffing::Policy.new do
      facet :metadata, tier: "cheap", terms: {
        author: "Who authored the work.",
        date:   "When the work was created."
      }
      ladder [ "cheap" ]
      verify_floor "cheap"
    end
    Enliterator.configure { |c| c.staffing = policy }
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap")
      .and_return(AffirmingStubLLM.new(proposed_key: "funder"))
  end

  def tend!(record)
    Enliterator::Tending::Visitor.new(record, facet: "metadata", embedder: embedder).call
  end

  def funder_warrant(context: nil)
    Enliterator::Vocabulary.candidates_for("metadata", context: context)
      &.find { |g| g[:proposed_key] == "funder" }
      &.dig(:count)
  end

  it "accrues warrant when a SECOND DISTINCT record affirms the same candidate key" do
    tend!(rec_a)
    expect(funder_warrant).to eq(1)

    tend!(rec_b)
    expect(funder_warrant).to eq(2)
  end

  it "a same-record re-tend does NOT raise warrant (warrant = distinct records, not raw rows)" do
    tend!(rec_a)
    tend!(rec_a)  # same record again

    # Two pending ROWS exist (persist_suggestions! does not dedup) ...
    expect(Enliterator::Suggestion.where(proposed_key: "funder", status: "pending").count).to eq(2)
    # ... but warrant counts DISTINCT records, so it stays 1.
    expect(funder_warrant).to eq(1)
  end

  it "mints no synonym — affirmation re-files the SAME key, not a variant" do
    tend!(rec_a)
    tend!(rec_b)
    keys = Enliterator::Vocabulary.candidates_for("metadata", context: nil).map { |g| g[:proposed_key] }
    expect(keys).to eq(%w[funder])
  end

  describe "a key resolved in an ANCESTOR context is not offered to a child reader" do
    let(:root)  { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
    let(:child) { Enliterator::Context.create!(key: "crs", name: "CRS", parent: root) }

    it "suppresses a child candidate whose key the curator already resolved at the root" do
      # Pending demand for 'funder' arises IN the child context.
      Enliterator::Suggestion.create!(tendable: rec_a, facet: "metadata", proposed_key: "funder",
                                      rationale: "r", status: "pending", context: child)
      # The curator rejected 'funder' at the ROOT (an ancestor) — a verdict reads down.
      Enliterator::Suggestion.create!(tendable: rec_b, facet: "metadata", proposed_key: "funder",
                                      rationale: "r", status: "rejected", context: root)

      keys = Enliterator::Vocabulary.candidates_for("metadata", context: child)&.map { |g| g[:proposed_key] } || []
      expect(keys).not_to include("funder")
    end
  end
end
