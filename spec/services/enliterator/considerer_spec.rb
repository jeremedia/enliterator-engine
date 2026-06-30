# frozen_string_literal: true

require "rails_helper"

# v0.8 the considerer — reasons over the whole open field, AUTO-APPLIES reversible
# verdicts (maps onto existing keys + confident rejects) and HOLDS approves (a
# contract change) for human ratification.
RSpec.describe Enliterator::Considerer do
  let(:w) { Widget.create!(title: "A", body: "x") }

  # Returns a fixed slate regardless of input — the LLM stand-in.
  class SlateStubLLM
    def initialize(recs) = (@recs = recs)
    def model_id = "stub-quality"
    def decide(messages:, schema:, tool_name:, tags: [])
      { "recommendations" => @recs }
    end
  end

  before do
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract.", authored_by: "The author(s)." }
        ladder [ "cheap", "quality" ]
      end
    end
    %w[author noise keywords].each do |k|
      Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: k, rationale: "r-#{k}", status: "pending")
    end
  end

  def consider_with(recs)
    described_class.new(llm: SlateStubLLM.new(recs)).consider!
  end

  it "auto-applies a confident map onto an existing canonical key" do
    summary = consider_with([ { "proposed_key" => "author", "decision" => "map", "map_to" => "authored_by", "rationale" => "synonym", "confidence" => 0.95 } ])
    s = Enliterator::Suggestion.find_by(proposed_key: "author")
    expect(s.status).to eq("mapped")
    expect(s.mapped_to).to eq("authored_by")
    expect(summary[:auto_mapped]).to eq(1)
  end

  it "auto-applies a confident reject" do
    consider_with([ { "proposed_key" => "noise", "decision" => "reject", "rationale" => "junk", "confidence" => 0.9 } ])
    expect(Enliterator::Suggestion.find_by(proposed_key: "noise").status).to eq("rejected")
  end

  it "HOLDS an approve as a recommendation — never auto-applies a contract change" do
    consider_with([ { "proposed_key" => "keywords", "decision" => "approve", "rationale" => "durable new concept", "confidence" => 0.9 } ])
    expect(Enliterator::Suggestion.find_by(proposed_key: "keywords").status).to eq("pending")
    term = Enliterator::ProposedTerm.find_by(proposed_key: "keywords")
    expect(term.recommended_decision).to eq("approve")
    expect(term.recommended_rationale).to eq("durable new concept")
  end

  it "HOLDS a map onto a NON-existent canonical key (can't map to a key that doesn't exist)" do
    consider_with([ { "proposed_key" => "author", "decision" => "map", "map_to" => "bogus", "rationale" => "x", "confidence" => 0.99 } ])
    expect(Enliterator::Suggestion.find_by(proposed_key: "author").status).to eq("pending")
    expect(Enliterator::ProposedTerm.find_by(proposed_key: "author").recommended_map_to).to eq("bogus")
  end

  it "HOLDS a low-confidence verdict instead of applying it" do
    consider_with([ { "proposed_key" => "noise", "decision" => "reject", "rationale" => "maybe", "confidence" => 0.3 } ])
    expect(Enliterator::Suggestion.find_by(proposed_key: "noise").status).to eq("pending")
  end

  it "summarizes the slate" do
    summary = consider_with([
      { "proposed_key" => "author",   "decision" => "map",     "map_to" => "authored_by", "rationale" => "syn", "confidence" => 0.95 },
      { "proposed_key" => "noise",    "decision" => "reject",  "rationale" => "junk",      "confidence" => 0.9 },
      { "proposed_key" => "keywords", "decision" => "approve", "rationale" => "new",       "confidence" => 0.9 }
    ])
    expect(summary).to include(considered: 3, auto_mapped: 1, auto_rejected: 1, approves_recommended: 1)
  end

  it "with the Null adapter (no gateway) is a safe no-op" do
    Enliterator.configuration.allow_null_llm = true
    summary = described_class.new.consider! # resolves to Null -> {} -> no recs
    expect(summary[:auto_mapped]).to eq(0)
    expect(Enliterator::Suggestion.pending.count).to eq(3)
  end

  # ---- v0.47 batching: considerer_batch_size --------------------------------
  describe "considerer_batch_size batching" do
    # A spy adapter that returns pre-loaded per-call responses and counts decide() calls.
    # Each element of per_call_recs is the recommendations array for that call index.
    class BatchSpyLLM
      attr_reader :call_count
      def initialize(per_call_recs)
        @per_call_recs = per_call_recs
        @call_count = 0
      end
      def model_id = "batch-spy"
      def decide(messages:, schema:, tool_name:, tags: [])
        recs = @per_call_recs[@call_count] || []
        @call_count += 1
        { "recommendations" => recs }
      end
    end

    # Raises on the 2nd decide() call to simulate a mid-batch failure.
    class RaisingOnSecondLLM
      def initialize(first_recs)
        @first_recs = first_recs
        @call_count = 0
      end
      def model_id = "raising-spy"
      def decide(messages:, schema:, tool_name:, tags: [])
        @call_count += 1
        raise "simulated timeout" if @call_count > 1
        { "recommendations" => @first_recs }
      end
    end

    before do
      # Outer before already created 3 suggestions: author, noise, keywords.
      # Add 2 more so we have 5 total: author, extra1, extra2, keywords, noise
      # (alphabetical order after pressure tie-break in scoped_terms).
      %w[extra1 extra2].each do |k|
        Enliterator::Suggestion.create!(
          tendable: w, facet: "summary", proposed_key: k,
          rationale: "r-#{k}", status: "pending"
        )
      end
      Enliterator.configuration.considerer_batch_size = 2
    end

    # scoped_terms: by_pressure DESC then proposed_key ASC → all pressure=1, so alpha:
    #   [author, extra1, extra2, keywords, noise]
    # Slices at batch_size=2: [author,extra1], [extra2,keywords], [noise]
    # canonical keys from staffing: authored_by, summary

    let(:per_call_recs) do
      [
        # Slice 0: author, extra1
        [
          { "proposed_key" => "author",  "decision" => "map",    "map_to" => "authored_by", "rationale" => "synonym", "confidence" => 0.95 },
          { "proposed_key" => "extra1",  "decision" => "reject",  "rationale" => "junk",     "confidence" => 0.9 }
        ],
        # Slice 1: extra2, keywords
        [
          { "proposed_key" => "extra2",   "decision" => "approve", "rationale" => "new concept", "confidence" => 0.9 },
          { "proposed_key" => "keywords", "decision" => "map",    "map_to" => "summary",     "rationale" => "synonym", "confidence" => 0.9 }
        ],
        # Slice 2: noise
        [
          { "proposed_key" => "noise",   "decision" => "reject",  "rationale" => "noise",    "confidence" => 0.9 }
        ]
      ]
    end

    let(:spy)        { BatchSpyLLM.new(per_call_recs) }
    let(:considerer) { described_class.new(llm: spy) }

    it "calls adapter.decide once per slice — 3 calls for 5 terms at batch_size=2" do
      considerer.consider!
      expect(spy.call_count).to eq(3)
    end

    it "aggregates the summary correctly across all batches" do
      summary = considerer.consider!
      expect(summary).to include(
        considered:           5,
        auto_mapped:          2,
        auto_rejected:        2,
        approves_recommended: 1,
        held:                 0
      )
    end

    it "persists slice-1 verdicts even when the adapter raises on slice 2 (partial-progress durability)" do
      raising_spy = RaisingOnSecondLLM.new(per_call_recs[0])
      expect { described_class.new(llm: raising_spy).consider! }.to raise_error("simulated timeout")
      # Slice 1 (author→map, extra1→reject) must already be committed to the DB
      expect(Enliterator::Suggestion.find_by(proposed_key: "author").status).to eq("mapped")
      expect(Enliterator::Suggestion.find_by(proposed_key: "extra1").status).to eq("rejected")
      # Slice 2 terms are still pending (the call that would process them never ran)
      expect(Enliterator::Suggestion.find_by(proposed_key: "extra2").status).to eq("pending")
      expect(Enliterator::Suggestion.find_by(proposed_key: "keywords").status).to eq("pending")
    end

    it "makes exactly ONE decide call when batch_size >= term count (back-compat)" do
      Enliterator.configuration.considerer_batch_size = 100
      all_recs = per_call_recs.flatten(1) # all 5 recs in one response
      single_spy = BatchSpyLLM.new([all_recs])
      described_class.new(llm: single_spy).consider!
      expect(single_spy.call_count).to eq(1)
    end

    it "yields cumulative (done, total) after each batch when a block is given" do
      yields = []
      considerer.consider! { |done, total| yields << [done, total] }
      expect(yields).to eq([[2, 5], [4, 5], [5, 5]])
    end

    it "returns the summary normally and has no side effects when no block is given" do
      summary = nil
      expect { summary = considerer.consider! }.not_to raise_error
      expect(summary[:considered]).to eq(5)
      expect(spy.call_count).to eq(3)
    end
  end
end
