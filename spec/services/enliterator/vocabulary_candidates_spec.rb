# frozen_string_literal: true

require "rails_helper"

# Stage 1 — read-time warrant accrual. `candidates_for` is the bounded, warrant-ranked
# CANDIDATE vocabulary a reader is shown: live pending Suggestions (via `Suggestion.gaps`),
# minus what is already established or resolved, gathered at the EXACT context. Returns nil
# (not []) when empty so the visitor's `!candidates.nil?` gate omits the kwarg.
RSpec.describe "Enliterator::Vocabulary.candidates_for" do
  let(:w1) { Widget.create!(title: "A", body: "x") }
  let(:w2) { Widget.create!(title: "B", body: "y") }
  let(:w3) { Widget.create!(title: "C", body: "z") }

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
      end
    end
  end

  def propose!(record, key, status: "pending", context: nil)
    Enliterator::Suggestion.create!(tendable: record, facet: "summary", proposed_key: key,
                                    rationale: "r", example_value: "e", status: status, context: context)
  end

  it "returns live pending candidates for the facet, ranked by distinct-record demand" do
    propose!(w1, "economic_impact"); propose!(w2, "economic_impact")  # 2 distinct records
    propose!(w3, "outlook")                                           # 1 record

    out = Enliterator::Vocabulary.candidates_for("summary", context: nil)
    expect(out.map { |g| g[:proposed_key] }).to eq(%w[economic_impact outlook]) # demand order
    expect(out.first[:count]).to eq(2)
    expect(out.first[:sample_rationale]).to eq("r")
  end

  it "excludes ESTABLISHED keys (code terms AND curator-approved)" do
    propose!(w1, "summary")            # 'summary' is a code term → established
    propose!(w1, "keywords")
    Enliterator::Suggestion.create!(tendable: w2, facet: "summary", proposed_key: "keywords",
                                    rationale: "r", status: "approved") # approved → established

    keys = Enliterator::Vocabulary.candidates_for("summary", context: nil)&.map { |g| g[:proposed_key] } || []
    expect(keys).not_to include("summary", "keywords")
  end

  it "excludes RESOLVED keys (mapped/rejected/approved), not just established" do
    propose!(w1, "noise", status: "rejected")  # a verdict — resolved
    propose!(w2, "noise", status: "pending")   # fresh pending (resurged) for the same key
    keys = Enliterator::Vocabulary.candidates_for("summary", context: nil)&.map { |g| g[:proposed_key] } || []
    expect(keys).not_to include("noise")
  end

  it "returns nil (NOT []) when there are no candidates" do
    expect(Enliterator::Vocabulary.candidates_for("summary", context: nil)).to be_nil
  end

  it "caps at limit" do
    propose!(w1, "a"); propose!(w1, "b"); propose!(w1, "c")
    expect(Enliterator::Vocabulary.candidates_for("summary", context: nil, limit: 2).size).to eq(2)
  end

  describe "exact-context gather (pending rows do NOT inherit)" do
    let(:root)  { Enliterator::Context.create!(key: "hsdl", name: "HSDL") }
    let(:child) { Enliterator::Context.create!(key: "crs", name: "CRS", parent: root) }
    let(:sib)   { Enliterator::Context.create!(key: "eo", name: "EO", parent: root) }

    it "gathers only the exact context's pending; a sibling's pending does not leak" do
      propose!(w1, "child_key", context: child)
      propose!(w2, "sib_key", context: sib)
      keys = Enliterator::Vocabulary.candidates_for("summary", context: child).map { |g| g[:proposed_key] }
      expect(keys).to include("child_key")
      expect(keys).not_to include("sib_key")
    end

    it "root (context: nil) gathers only NULL-context pending, not all contexts" do
      propose!(w1, "root_key", context: nil)
      propose!(w2, "child_key", context: child)
      keys = Enliterator::Vocabulary.candidates_for("summary", context: nil).map { |g| g[:proposed_key] }
      expect(keys).to include("root_key")
      expect(keys).not_to include("child_key")
    end
  end

  describe "the established: param (avoid recomputing Vocabulary.for per record)" do
    it "uses the PASSED established set for exclusion (string-normalized)" do
      propose!(w1, "keepme")
      propose!(w1, "dropme")
      # established passed with a SYMBOL key — must still exclude the String gap key
      out = Enliterator::Vocabulary.candidates_for("summary", context: nil, established: { dropme: "x" })
      expect(out.map { |g| g[:proposed_key] }).to eq(%w[keepme])
    end

    it "falls back to Vocabulary.for when established is nil (standalone callers)" do
      propose!(w1, "summary")  # code-established
      propose!(w1, "novel")
      out = Enliterator::Vocabulary.candidates_for("summary", context: nil, established: nil)
      expect(out.map { |g| g[:proposed_key] }).to eq(%w[novel])
    end
  end
end
