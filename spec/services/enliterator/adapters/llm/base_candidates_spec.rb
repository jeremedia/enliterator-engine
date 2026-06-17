# frozen_string_literal: true

require "rails_helper"

# Stage 1 — the CANDIDATE-vocabulary prompt block. `system_for` appends a candidate
# block (the three-tier affirm instruction + the key-vs-value discipline) as a SIBLING
# after the contract block, gated on `candidates&.any?`. With no/empty candidates the
# system text is byte-identical to today, and the structured-output schema is never
# touched (affirmation lives in the prompt, not the schema — so its golden stays clean).
RSpec.describe "Enliterator::Adapters::LLM::Base#system_for candidate block (stage 1)" do
  let(:adapter)  { Enliterator::Adapters::LLM::Null.new }
  let(:contract) { { "author" => "Who authored it.", "date" => "When." } }
  let(:candidates) do
    [ { proposed_key: "funding_source", count: 4, sample_rationale: "names the funder" },
      { proposed_key: "jurisdiction",   count: 2, sample_rationale: "the governing body" } ]
  end

  it "appends a CANDIDATE block with the candidate keys and an affirm instruction" do
    sys = adapter.system_for(contract, candidates: candidates)
    expect(sys).to match(/CONTROLLED VOCABULARY/i)           # contract block still present
    expect(sys).to match(/candidate/i)                        # the new block
    expect(sys).to include("funding_source", "jurisdiction")  # the candidate keys
    expect(sys).to match(/affirm|re-?propose/i)               # three-tier affirm instruction
    expect(sys).to match(/value|index/i)                      # discipline (B): value-vs-key
  end

  it "is byte-identical to the no-candidates system text when candidates is nil" do
    expect(adapter.system_for(contract, candidates: nil)).to eq(adapter.system_for(contract))
  end

  it "is byte-identical when candidates is an empty array" do
    expect(adapter.system_for(contract, candidates: [])).to eq(adapter.system_for(contract))
  end

  it "renders NO candidate block for an unconstrained facet (candidates require a contract)" do
    expect(adapter.system_for(nil, candidates: candidates)).to eq(adapter.system_for(nil))
    expect(adapter.system_for(nil, candidates: candidates)).not_to match(/candidate/i)
  end

  it "leaves schema_for and the suggestions description untouched (affirmation is prompt-only)" do
    schema = adapter.schema_for(contract)
    expect(schema["properties"]).to have_key("suggestions")
    # the suggestions-array description keeps its novel-keys framing — no candidate text leaked in
    expect(schema.dig("properties", "suggestions", "description")).not_to match(/candidate/i)
  end
end
