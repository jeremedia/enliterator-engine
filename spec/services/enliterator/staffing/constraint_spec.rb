# frozen_string_literal: true

require "rails_helper"

# Constraint enforcement — an on-prem-only record never escalates off-prem.
#
# The policy ladder is ["cheap","quality"] with on_prem_tiers ["cheap"]. A
# tendable that answers enliterator_on_prem_only? => true has its allowed ladder
# clamped to ["cheap"], so even a low-confidence cheap visit CANNOT climb to the
# off-prem "quality" tier. The record runs once, on-prem, and writes from cheap.
RSpec.describe "Enliterator::Tending::Visitor on-prem constraint (staffing path)" do
  class ConstraintStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    attr_reader :tier, :calls

    def initialize(tier:, confidence:)
      @tier       = tier
      @confidence = confidence
      @calls      = 0
    end

    def model_id = "model-#{@tier}"

    def tend(text:, stream:, state:, neighbors:, tags: [])
      @calls += 1
      Result.new(
        parsed: { "claims" => [ { "key" => "summary", "op" => "ADD", "value" => "on-prem-only" } ],
                  "confidence" => @confidence },
        raw:    { "tier" => @tier },
        tokens: { "input" => 1, "output" => 1, "total" => 2 }
      )
    end
  end

  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # An on-prem-only widget: define the host hook on the instance's singleton so
  # the policy clamps its ladder to the on-prem tiers.
  let(:widget) do
    Widget.create!(title: "Classified", body: "must stay on-prem").tap do |w|
      def w.enliterator_on_prem_only? = true
    end
  end

  let(:cheap)   { ConstraintStubLLM.new(tier: "cheap",   confidence: 0.1) } # low => would escalate if allowed
  let(:quality) { ConstraintStubLLM.new(tier: "quality", confidence: 0.99) }

  before do
    policy = Enliterator::Staffing::Policy.new do
      assign :summary, tier: "cheap"
      ladder ["cheap", "quality"]
      verify_floor "cheap" # cheap may verify here so the test isolates the constraint
      on_prem_tiers ["cheap"]
      max_promotions 1
    end
    Enliterator.configure { |c| c.staffing = policy }

    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality)
  end

  it "never invokes the off-prem quality tier" do
    Enliterator::Tending::Visitor.new(widget, stream: "summary", embedder: embedder).call
    expect(cheap.calls).to eq(1)
    expect(quality.calls).to eq(0)
  end

  it "runs a single applied cheap visit (no escalation despite low confidence)" do
    Enliterator::Tending::Visitor.new(widget, stream: "summary", embedder: embedder).call

    visits = widget.enliterator_visits.to_a
    expect(visits.length).to eq(1)
    expect(visits.first.tier).to eq("cheap")
    expect(visits.first.applied).to be(true)
    expect(visits.first.escalated_from_id).to be_nil
  end

  it "writes the claim from the on-prem cheap tier" do
    Enliterator::Tending::Visitor.new(widget, stream: "summary", embedder: embedder).call
    claim = widget.enliterator_claims.live.find_by(key: "summary")
    expect(claim).to be_present
    expect(claim.tier).to eq("cheap")
  end
end
