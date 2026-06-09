# frozen_string_literal: true

require "rails_helper"

# v0.3 §4 — the Visitor's contract-aware staffing path.
#
# When a facet has an output contract, the Visitor threads `contract:` into the
# per-tier #tend, reconciles ONLY claims whose key is in the controlled vocabulary
# (off-list keys are dropped — the schema enum should prevent them, this is the
# safety net), and persists the model's `suggestions` as Enliterator::Suggestion
# rows with full provenance, firing config.suggestion_sink per row.
RSpec.describe "Enliterator::Tending::Visitor facet contracts (staffing path)" do
  # A per-tier fake adapter whose #tend ACCEPTS `contract:` (gateway-shaped, plus
  # the v0.3 keyword). It records the contract it was handed so the spec can prove
  # the Visitor threaded it, and returns a canned payload: one allowed-key claim,
  # one off-list-key claim, and one suggestion.
  class ContractStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    attr_reader :tier, :captured_contracts, :calls

    def initialize(tier:, parsed:, confidence:)
      @tier               = tier
      @parsed             = parsed
      @confidence         = confidence
      @captured_contracts = []
      @calls              = 0
    end

    def model_id
      "model-#{@tier}"
    end

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil)
      @calls += 1
      @captured_contracts << contract
      payload = @parsed.merge("confidence" => @confidence)
      Result.new(
        parsed: payload,
        raw:    { "tier" => @tier },
        tokens: { "input" => 7, "output" => 3, "total" => 10 }
      )
    end
  end

  let(:widget) { Widget.create!(title: "Thesis", body: "A record worth governing.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # The cheap tier proposes:
  #   - an ALLOWED claim ("author")          => must be written
  #   - an OFF-LIST claim ("institution")    => must NOT be written
  #   - a SUGGESTION ("institution")         => must become a Suggestion row
  let(:cheap) do
    ContractStubLLM.new(
      tier:       "cheap",
      parsed:     {
        "claims" => [
          { "key" => "author",      "op" => "ADD", "value" => "Ada Lovelace" },
          { "key" => "institution", "op" => "ADD", "value" => "Off-list U." }
        ],
        "suggestions" => [
          {
            "proposed_key"  => "institution",
            "rationale"     => "The work names an institution no allowed key covers.",
            "example_value" => { "name" => "Naval Postgraduate School" }
          }
        ]
      },
      confidence: 0.95 # high => no escalation; the cheap tier finalizes
    )
  end

  # The sink records every Suggestion it is handed.
  let(:sink_calls) { [] }

  before do
    policy = Enliterator::Staffing::Policy.new do
      facet :metadata, tier: "cheap", terms: {
        author: "Who authored the work.",
        date:   "When the work was created."
      }
      ladder ["cheap", "quality"]
      verify_floor "cheap"
      max_promotions 1
    end

    captured = sink_calls
    Enliterator.configure do |c|
      c.staffing        = policy
      c.suggestion_sink = ->(s) { captured << s }
    end

    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
  end

  def tend!
    Enliterator::Tending::Visitor.new(widget, facet: "metadata", embedder: embedder).call
  end

  it "threads the facet's contract into #tend" do
    tend!
    contract = cheap.captured_contracts.first
    expect(contract).to eq(
      "author" => "Who authored the work.",
      "date"   => "When the work was created."
    )
  end

  it "writes the ALLOWED-key claim" do
    tend!
    author = widget.enliterator_claims.live.find_by(key: "author")
    expect(author).to be_present
    expect(author.value).to eq("Ada Lovelace")
  end

  it "does NOT write the OFF-LIST-key claim (safety-net filter)" do
    tend!
    expect(widget.enliterator_claims.where(key: "institution")).to be_empty
    # Only the single allowed claim is live.
    live_keys = widget.enliterator_claims.live.pluck(:key)
    expect(live_keys).to contain_exactly("author")
  end

  it "persists the model's suggestion as an Enliterator::Suggestion with provenance" do
    final = tend!

    suggestion = Enliterator::Suggestion.find_by(proposed_key: "institution")
    expect(suggestion).to be_present
    expect(suggestion.tendable).to eq(widget)
    expect(suggestion.facet).to eq("metadata")
    expect(suggestion.tier).to eq("cheap")
    expect(suggestion.model).to eq("model-cheap")
    expect(suggestion.visit).to eq(final)
    expect(suggestion.rationale).to include("institution")
    expect(suggestion.example_value).to eq("name" => "Naval Postgraduate School")
    expect(suggestion.status).to eq("pending")
  end

  it "fires config.suggestion_sink once per created suggestion" do
    tend!
    expect(sink_calls.length).to eq(1)
    expect(sink_calls.first).to be_a(Enliterator::Suggestion)
    expect(sink_calls.first.proposed_key).to eq("institution")
  end

  describe "an UNCONSTRAINED facet (no contract) — v0.2 byte-identical" do
    let(:cheap) do
      ContractStubLLM.new(
        tier:   "cheap",
        parsed: {
          "claims" => [
            { "key" => "anything", "op" => "ADD", "value" => "freelanced" }
          ],
          "suggestions" => [
            { "proposed_key" => "ignored", "rationale" => "no contract" }
          ]
        },
        confidence: 0.95
      )
    end

    before do
      policy = Enliterator::Staffing::Policy.new do
        assign :metadata, tier: "cheap"   # NO keys => unconstrained
        ladder ["cheap", "quality"]
        verify_floor "cheap"
      end
      captured = sink_calls
      Enliterator.configure do |c|
        c.staffing        = policy
        c.suggestion_sink = ->(s) { captured << s }
      end
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    end

    it "does NOT thread a contract into #tend (nil)" do
      tend!
      expect(cheap.captured_contracts.first).to be_nil
    end

    it "writes ALL proposed claims (open keys, no filter)" do
      tend!
      expect(widget.enliterator_claims.live.find_by(key: "anything")).to be_present
    end

    it "still persists suggestions if the model happens to emit them, firing the sink" do
      # The contract-absent path doesn't suppress suggestions the model returns —
      # persistence is gated on the model emitting them, not on a contract.
      tend!
      expect(Enliterator::Suggestion.find_by(proposed_key: "ignored")).to be_present
      expect(sink_calls.length).to eq(1)
    end
  end
end
