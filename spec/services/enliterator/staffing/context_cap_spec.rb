# frozen_string_literal: true

require "rails_helper"

# v0.2 declared `context_cap tier, tokens` with the documented intent that
# "inputs over it must escalate/chunk" — and then never wired it: the reader
# had zero callers, no specs, and no host declared one. This spec drives the
# knob to its stated meaning: a tier whose context window cannot hold this
# record's text is not ELIGIBLE, so the ladder starts (and climbs) at a tier
# that can. Truncation is deliberately NOT the semantic — silently amputating
# the input is exactly the degradation this engine refuses.
#
# Byte-identical discipline: a policy that declares no cap must take a fast
# path that never even reads the record's text.
RSpec.describe "Staffing context caps" do
  # A per-tier fake adapter (mirrors the escalation spec's harness, renamed so
  # the two files never collide on the constant).
  class CapStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    attr_reader :tier, :calls

    def initialize(tier:, confidence: 0.95)
      @tier       = tier
      @confidence = confidence
      @calls      = 0
    end

    def model_id = "model-#{@tier}"

    def tend(text:, facet:, state:, neighbors:, tags: [])
      @calls += 1
      Result.new(
        parsed: { "claims" => [ { "key" => "summary", "op" => "ADD", "value" => "from-#{@tier}" } ],
                  "confidence" => @confidence },
        raw:    { "tier" => @tier },
        tokens: { "input" => 10, "output" => 5, "total" => 15 }
      )
    end
  end

  let(:off_prem_record) { Object.new }

  describe Enliterator::Staffing::Policy do
    let(:uncapped) do
      described_class.new do
        assign :summary, tier: "cheap"
        ladder [ "cheap", "quality" ]
      end
    end

    let(:capped) do
      described_class.new do
        assign :summary, tier: "cheap"
        ladder [ "cheap", "quality" ]
        context_cap "cheap", 4096
      end
    end

    describe "#context_caps_declared?" do
      it "is false when the policy declares no cap" do
        expect(uncapped.context_caps_declared?).to be false
      end

      it "is true once a cap is declared" do
        expect(capped.context_caps_declared?).to be true
      end
    end

    describe "#tier_fits?" do
      it "is true for a tier with no declared cap, whatever the input size" do
        expect(capped.tier_fits?("quality", "x" * 10_000_000)).to be true
      end

      it "is false when the estimated input exceeds the tier's cap" do
        # 4096 tokens ≈ 16_384 chars at the documented 4-chars-per-token estimate
        expect(capped.tier_fits?("cheap", "x" * 40_000)).to be false
      end

      it "is true when the estimated input fits under the tier's cap" do
        expect(capped.tier_fits?("cheap", "x" * 400)).to be true
      end

      it "treats nil text as fitting (nothing to overflow)" do
        expect(capped.tier_fits?("cheap", nil)).to be true
      end
    end

    describe "#tiers_fitting" do
      it "removes tiers that cannot hold the input and preserves ladder order" do
        expect(capped.tiers_fitting(%w[cheap quality], "x" * 40_000)).to eq(%w[quality])
      end

      it "returns every tier when the input fits everywhere" do
        expect(capped.tiers_fitting(%w[cheap quality], "small")).to eq(%w[cheap quality])
      end

      it "returns an empty list when no tier can hold the input" do
        policy = described_class.new do
          assign :summary, tier: "cheap"
          ladder [ "cheap", "quality" ]
          context_cap "cheap", 100
          context_cap "quality", 200
        end
        expect(policy.tiers_fitting(%w[cheap quality], "x" * 40_000)).to eq([])
      end
    end
  end

  describe "the Visitor's tier routing" do
    let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
    let(:cheap)    { CapStubLLM.new(tier: "cheap") }
    let(:quality)  { CapStubLLM.new(tier: "quality") }

    before do
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
      allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality)
      allow(Enliterator).to receive(:embedder).and_return(embedder)
    end

    def configure_policy!(&block)
      policy = Enliterator::Staffing::Policy.new(&block)
      Enliterator.configure { |c| c.staffing = policy }
      policy
    end

    it "skips a tier that cannot hold the record and starts at one that can" do
      configure_policy! do
        assign :summary, tier: "cheap"
        ladder [ "cheap", "quality" ]
        context_cap "cheap", 4096
      end
      widget = Widget.create!(title: "Big", body: "x" * 40_000)

      visit = widget.tend!(facet: :summary)

      expect(cheap.calls).to eq(0)
      expect(quality.calls).to eq(1)
      expect(visit.tier).to eq("quality")
      expect(visit.escalation_step).to eq(0) # started there; not an escalation
    end

    it "starts at the assigned tier when the record fits under the cap" do
      configure_policy! do
        assign :summary, tier: "cheap"
        ladder [ "cheap", "quality" ]
        context_cap "cheap", 4096
      end
      widget = Widget.create!(title: "Small", body: "a modest body")

      widget.tend!(facet: :summary)

      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(0)
    end

    it "is untouched when the policy declares no cap, and never weighs the text to route" do
      policy = configure_policy! do
        assign :summary, tier: "cheap"
        ladder [ "cheap", "quality" ]
      end
      widget = Widget.create!(title: "Big", body: "x" * 40_000)
      # The fast path: with nothing declared, routing must not weigh the record
      # at all (a host's to_enliterator_text can be expensive to build).
      expect(policy).not_to receive(:tiers_fitting)

      widget.tend!(facet: :summary)

      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(0)
    end

    it "raises a clear error naming the size and the largest cap when nothing fits" do
      configure_policy! do
        assign :summary, tier: "cheap"
        ladder [ "cheap", "quality" ]
        context_cap "cheap", 100
        context_cap "quality", 200
      end
      widget = Widget.create!(title: "Enormous", body: "x" * 40_000)

      expect {
        widget.tend!(facet: :summary)
      }.to raise_error(Enliterator::ConfigurationError, /no staffing tier.*hold/i)
      expect(cheap.calls).to eq(0)
      expect(quality.calls).to eq(0)
    end
  end
end
