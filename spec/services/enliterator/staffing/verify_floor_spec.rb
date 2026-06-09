# frozen_string_literal: true

require "rails_helper"

# verify_floor enforcement — a cheap pass must not poison the compounding well.
#
# With verify_floor "quality": a "cheap"-only run (no higher tier; cheap asserts
# high confidence) leaves the claim "draft" — below the floor, may_verify? is
# false, so even a confident assertion cannot mint `verified`. A "quality" run
# (at/above the floor, asserting verified) MAY mark the claim "verified".
RSpec.describe "Enliterator::Tending::Visitor verify_floor (staffing path)" do
  class VerifyFloorStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    def initialize(tier:, claims:, confidence:)
      @tier       = tier
      @claims     = claims
      @confidence = confidence
    end

    def model_id = "model-#{@tier}"

    def tend(text:, facet:, state:, neighbors:, tags: [])
      Result.new(
        parsed: { "claims" => @claims, "confidence" => @confidence },
        raw:    { "tier" => @tier },
        tokens: { "input" => 1, "output" => 1, "total" => 2 }
      )
    end
  end

  let(:widget) { Widget.create!(title: "Acme", body: "verify-floor fodder") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def call_staffing!
    Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
  end

  describe "a cheap-only run cannot mint verified (below the floor)" do
    before do
      # cheap is BOTH the assigned tier and the only tier — but verify_floor is
      # quality, so the cheap tier is below the floor and may not verify.
      policy = Enliterator::Staffing::Policy.new do
        assign :summary, tier: "cheap"
        ladder ["cheap", "quality"]
        verify_floor "quality"
        max_promotions 1
      end
      Enliterator.configure { |c| c.staffing = policy }

      # High confidence AND an explicit verified assertion — yet it must stay draft.
      cheap = VerifyFloorStubLLM.new(
        tier: "cheap",
        claims: [ { "key" => "summary", "op" => "ADD", "value" => "cheap-truth",
                    "confidence" => 0.99, "status" => "verified" } ],
        confidence: 0.99 # high => no escalation; the cheap pass is final
      )
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    end

    it "leaves the claim 'draft' despite a confident verified assertion" do
      call_staffing!
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim).to be_present
      expect(claim.value).to eq("cheap-truth")
      expect(claim.status).to eq("draft")
      expect(claim.tier).to eq("cheap")
    end
  end

  describe "a quality run may mint verified (at the floor)" do
    before do
      policy = Enliterator::Staffing::Policy.new do
        assign :summary, tier: "quality"
        ladder ["cheap", "quality"]
        verify_floor "quality"
        max_promotions 1
      end
      Enliterator.configure { |c| c.staffing = policy }

      quality = VerifyFloorStubLLM.new(
        tier: "quality",
        claims: [ { "key" => "summary", "op" => "ADD", "value" => "verified-truth",
                    "confidence" => 0.97, "status" => "verified" } ],
        confidence: 0.97
      )
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality)
    end

    it "marks the claim 'verified' when the tier is at/above the floor and the model asserted it" do
      call_staffing!
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim).to be_present
      expect(claim.value).to eq("verified-truth")
      expect(claim.status).to eq("verified")
      expect(claim.tier).to eq("quality")
    end
  end
end
