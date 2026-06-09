# frozen_string_literal: true

require "rails_helper"

# Escalation is FOUNDATIONAL. This spec drives the POLICY path of the Visitor
# (no llm: injected) with per-tier fake adapters wired through Enliterator.llm.
#
# Policy: ladder ["cheap","quality"], verify_floor "quality", max_promotions 1.
# The "cheap" visit returns low confidence (< 0.6); the Visitor must escalate
# EXACTLY ONCE to "quality". We then assert the senior visit saw the junior's
# proposed claims, only the senior is applied:true and writes the claim, the
# junior is applied:false with the escalated relationship, and the recorded
# tier/escalation_step are correct. A second example proves max_promotions caps
# the climb even when the senior is also low-confidence.
RSpec.describe "Enliterator::Tending::Visitor escalation (staffing path)" do
  # A fake per-tier adapter. Conforms to the gateway-shaped contract: its #tend
  # accepts a `tags:` keyword (so the Visitor's tag-passing path is exercised),
  # captures every state + tags it was handed, and returns a canned parsed
  # payload + confidence. No network.
  class TierStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    attr_reader :tier, :captured_states, :captured_tags, :calls

    def initialize(tier:, parsed:, confidence:)
      @tier            = tier
      @parsed          = parsed
      @confidence      = confidence
      @captured_states = []
      @captured_tags   = []
      @calls           = 0
    end

    def model_id
      "model-#{@tier}"
    end

    def tend(text:, facet:, state:, neighbors:, tags: [])
      @calls += 1
      @captured_states << state
      @captured_tags   << tags
      payload = @parsed.merge("confidence" => @confidence)
      Result.new(
        parsed: payload,
        raw:    { "tier" => @tier },
        tokens: { "input" => 10, "output" => 5, "total" => 15 }
      )
    end
  end

  let(:widget) { Widget.create!(title: "Acme", body: "A record worth escalating.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def configure_policy!(max_promotions: 1)
    policy = Enliterator::Staffing::Policy.new do
      assign :summary, tier: "cheap"
      ladder ["cheap", "quality"]
      verify_floor "quality"
      max_promotions max_promotions
    end
    Enliterator.configure { |c| c.staffing = policy }
    policy
  end

  # Route Enliterator.llm(tier:) to the matching per-tier stub.
  def route_tiers!(cheap:, quality:)
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality)
  end

  describe "low-confidence junior escalates exactly once to the senior" do
    let(:cheap) do
      TierStubLLM.new(
        tier:       "cheap",
        parsed:     { "claims" => [
          { "key" => "summary", "op" => "ADD", "value" => "cheap-draft" }
        ] },
        confidence: 0.3 # below the 0.6 threshold => escalate
      )
    end

    let(:quality) do
      TierStubLLM.new(
        tier:       "quality",
        parsed:     { "claims" => [
          { "key" => "summary", "op" => "ADD", "value" => "quality-final" }
        ] },
        confidence: 0.95
      )
    end

    before do
      configure_policy!
      route_tiers!(cheap: cheap, quality: quality)
    end

    it "runs each tier exactly once (one escalation, no further climb)" do
      described_class_call!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(1)
    end

    it "records two visits: junior cheap (applied:false) and senior quality (applied:true)" do
      described_class_call!

      visits = widget.enliterator_visits.order(:id).to_a
      expect(visits.length).to eq(2)

      junior, senior = visits
      expect(junior.tier).to eq("cheap")
      expect(junior.applied).to be(false)
      expect(junior.escalation_step).to eq(0)

      expect(senior.tier).to eq("quality")
      expect(senior.applied).to be(true)
      expect(senior.escalation_step).to eq(1)
      expect(senior.escalated_from_id).to eq(junior.id)
    end

    it "hands the junior's proposed claims to the senior via state['proposed_by_lower_tier']" do
      described_class_call!

      senior_state = quality.captured_states.first
      proposed = senior_state["proposed_by_lower_tier"] || senior_state[:proposed_by_lower_tier]
      expect(proposed).to be_present
      keys = proposed.map { |c| c["key"] || c[:key] }
      expect(keys).to include("summary")
      values = proposed.map { |c| c["value"] || c[:value] }
      expect(values).to include("cheap-draft")
    end

    it "writes ONLY the senior's claim (the cheap draft never becomes live)" do
      described_class_call!

      live = widget.enliterator_claims.live.where(key: "summary").to_a
      expect(live.length).to eq(1)
      expect(live.first.value).to eq("quality-final")
      expect(live.first.tier).to eq("quality")
      expect(live.first.attributed_to).to eq("quality:model-quality")
    end

    it "returns the senior (final) visit from #call" do
      final = described_class_call!
      expect(final.tier).to eq("quality")
      expect(final.applied).to be(true)
    end

    it "emits spend tags carrying the tier and escalation step to the gateway adapter" do
      described_class_call!

      cheap_tags  = cheap.captured_tags.first
      senior_tags = quality.captured_tags.first

      expect(cheap_tags).to include("tier:cheap", "esc:0", "facet:summary")
      expect(senior_tags).to include("tier:quality", "esc:1")
    end
  end

  describe "max_promotions caps the climb" do
    # Both tiers are low-confidence; with max_promotions 1 we may climb only once.
    let(:cheap) do
      TierStubLLM.new(
        tier: "cheap",
        parsed: { "claims" => [ { "key" => "summary", "op" => "ADD", "value" => "c" } ] },
        confidence: 0.1
      )
    end
    let(:quality) do
      TierStubLLM.new(
        tier: "quality",
        parsed: { "claims" => [ { "key" => "summary", "op" => "ADD", "value" => "q" } ] },
        confidence: 0.1 # still low, but no higher tier and bound reached
      )
    end

    before do
      configure_policy!(max_promotions: 1)
      route_tiers!(cheap: cheap, quality: quality)
    end

    it "climbs at most once even though the senior is also low-confidence" do
      described_class_call!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(1)
      expect(widget.enliterator_visits.count).to eq(2)
      # The quality visit is the final one and is applied despite low confidence
      # (no further tier to climb to, bound reached) — it still WRITES.
      final = widget.enliterator_visits.order(:id).last
      expect(final.tier).to eq("quality")
      expect(final.applied).to be(true)
    end
  end

  describe "max_promotions 0 forbids any climb" do
    let(:cheap) do
      TierStubLLM.new(
        tier: "cheap",
        parsed: { "claims" => [ { "key" => "summary", "op" => "ADD", "value" => "c" } ] },
        confidence: 0.1 # low, but climbing is disallowed
      )
    end
    let(:quality) { TierStubLLM.new(tier: "quality", parsed: { "claims" => [] }, confidence: 0.9) }

    before do
      configure_policy!(max_promotions: 0)
      route_tiers!(cheap: cheap, quality: quality)
    end

    it "runs only the junior and applies it (no escalation despite low confidence)" do
      described_class_call!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(0)

      visits = widget.enliterator_visits.to_a
      expect(visits.length).to eq(1)
      expect(visits.first.tier).to eq("cheap")
      expect(visits.first.applied).to be(true)
    end
  end

  # Helper: run the Visitor's staffing path (no llm: injected).
  def described_class_call!
    Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
  end
end
