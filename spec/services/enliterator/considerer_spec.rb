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
        stream :summary, tier: "cheap", keys: { summary: "An abstract.", authored_by: "The author(s)." }
        ladder [ "cheap", "quality" ]
      end
    end
    %w[author noise keywords].each do |k|
      Enliterator::Suggestion.create!(tendable: w, stream: "summary", proposed_key: k, rationale: "r-#{k}", status: "pending")
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
end
