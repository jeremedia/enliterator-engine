# frozen_string_literal: true

require "rails_helper"

# v0.9 convergence at tend time: a key the curator already resolved (mapped/
# rejected) is NOT re-filed (it's suppressed + the term's post_verdict_attempts
# bumps); an APPROVED key is in the effective contract, so the model emits it as a
# claim that survives the contract filter.
RSpec.describe "Enliterator::Tending::Visitor convergence (v0.9)" do
  let(:widget)   { Widget.create!(title: "T", body: "b") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Returns canned claims + suggestions, honoring the optional-kwarg arity.
  class ConvStub
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    def initialize(claims: [], suggestions: []) = (@claims = claims; @suggestions = suggestions)
    def model_id = "model-cheap"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: { "claims" => @claims, "confidence" => 0.9, "suggestions" => @suggestions }, raw: {}, tokens: {})
    end
  end

  def configure_policy!
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "cheap", terms: { summary: "An abstract." }
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
    end
  end

  def tend_with!(stub)
    configure_policy!
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
    Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
  end

  it "files a Suggestion for an UNRESOLVED proposed key" do
    expect {
      tend_with!(ConvStub.new(suggestions: [ { "proposed_key" => "fresh_key", "rationale" => "new" } ]))
    }.to change { Enliterator::Suggestion.where(proposed_key: "fresh_key").count }.by(1)
  end

  it "SUPPRESSES a re-proposal of a resolved key and bumps post_verdict_attempts" do
    Enliterator::Suggestion.create!(tendable: widget, facet: "summary", proposed_key: "old_key", rationale: "r", status: "rejected")
    Enliterator::ProposedTerm.create!(proposed_key: "old_key", post_verdict_attempts: 0)

    expect {
      tend_with!(ConvStub.new(suggestions: [ { "proposed_key" => "old_key", "rationale" => "again" } ]))
    }.not_to change { Enliterator::Suggestion.where(proposed_key: "old_key", status: "pending").count }
    expect(Enliterator::ProposedTerm.find_by(proposed_key: "old_key").post_verdict_attempts).to eq(1)
  end

  it "an APPROVED key is in the effective contract, so a model claim for it is written" do
    Enliterator::Suggestion.create!(tendable: widget, facet: "summary", proposed_key: "keywords", rationale: "r", status: "approved")
    Enliterator::ProposedTerm.create!(proposed_key: "keywords", recommended_rationale: "salient terms")

    tend_with!(ConvStub.new(claims: [ { "key" => "keywords", "op" => "ADD", "value" => "FOIA, AI" } ]))
    expect(widget.enliterator_claims.live.find_by(key: "keywords")&.value).to eq("FOIA, AI")
  end
end
