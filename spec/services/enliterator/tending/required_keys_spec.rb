# frozen_string_literal: true

require "rails_helper"

# v0.5 escalate-on-empty-required-key. The incident behind it: a required author
# came back EMPTY at confidence 1.0 and passed as success (no escalation). Now an
# unmet required key forces escalation regardless of confidence, and a still-unmet
# key at the top of the climb bars `verified` and flags the reconciliation.
RSpec.describe "Enliterator::Tending::Visitor required-key escalation (staffing path)" do
  # Gateway-shaped stub: accepts tags:/contract:/required: (captures required to
  # prove the Visitor threads it), returns canned claims + confidence. No network.
  class ReqStub
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    attr_reader :tier, :calls, :captured_required

    def initialize(tier:, claims:, confidence:)
      @tier = tier; @claims = claims; @confidence = confidence
      @calls = 0; @captured_required = []
    end

    def model_id = "model-#{@tier}"

    def tend(text:, stream:, state:, neighbors:, tags: [], contract: nil, required: nil)
      @calls += 1
      @captured_required << required
      Result.new(parsed: { "claims" => @claims, "confidence" => @confidence },
                 raw: { "tier" => @tier }, tokens: {})
    end
  end

  let(:widget)   { Widget.create!(title: "Thesis", body: "A thesis with a title page.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def configure_policy!(max_promotions: 1)
    policy = Enliterator::Staffing::Policy.new do
      stream :authorship, tier: "cheap",
             keys: { authored_by: "The author(s).", advisor: "The advisor(s)." },
             required: [ :authored_by ]
      ladder [ "cheap", "quality" ]
      verify_floor "quality"
      max_promotions max_promotions
    end
    Enliterator.configure { |c| c.staffing = policy }
    policy
  end

  def route_tiers!(cheap:, quality:)
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality)
  end

  def tend!
    Enliterator::Tending::Visitor.new(widget, stream: "authorship", embedder: embedder).call
  end

  describe "required key ABSENT at high confidence still escalates" do
    let(:cheap) do
      ReqStub.new(tier: "cheap", confidence: 0.95, # high — would NOT escalate on confidence
                  claims: [ { "key" => "advisor", "op" => "ADD", "value" => "Dr. Adviser" } ])
    end
    let(:quality) do
      ReqStub.new(tier: "quality", confidence: 0.95,
                  claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "Jane Doe" },
                            { "key" => "advisor", "op" => "ADD", "value" => "Dr. Adviser" } ])
    end
    before { configure_policy!; route_tiers!(cheap: cheap, quality: quality) }

    it "climbs to quality and writes the author the senior found" do
      tend!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(1)
      live = widget.enliterator_claims.live.find_by(key: "authored_by")
      expect(live&.value).to eq("Jane Doe")
    end

    it "threads required: into the adapter" do
      tend!
      expect(cheap.captured_required.first).to eq([ "authored_by" ])
    end
  end

  describe "required key BLANK escalates (empty string and empty array)" do
    let(:quality) do
      ReqStub.new(tier: "quality", confidence: 0.9,
                  claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "Jane Doe" } ])
    end

    it "treats an empty-string value as unmet" do
      cheap = ReqStub.new(tier: "cheap", confidence: 0.95,
                          claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ])
      configure_policy!; route_tiers!(cheap: cheap, quality: quality)
      tend!
      expect(quality.calls).to eq(1)
      expect(widget.enliterator_claims.live.find_by(key: "authored_by")&.value).to eq("Jane Doe")
    end

    it "treats an empty-array value as unmet" do
      cheap = ReqStub.new(tier: "cheap", confidence: 0.95,
                          claims: [ { "key" => "authored_by", "op" => "ADD", "value" => [] } ])
      configure_policy!; route_tiers!(cheap: cheap, quality: quality)
      tend!
      expect(quality.calls).to eq(1)
    end
  end

  describe "required key SATISFIED does not escalate" do
    let(:cheap) do
      ReqStub.new(tier: "cheap", confidence: 0.95,
                  claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "Jane Doe" } ])
    end
    let(:quality) { ReqStub.new(tier: "quality", confidence: 0.95, claims: []) }
    before { configure_policy!; route_tiers!(cheap: cheap, quality: quality) }

    it "runs only the cheap tier (met + confident)" do
      tend!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(0)
      expect(widget.enliterator_visits.count).to eq(1)
    end
  end

  describe "still unmet at the TOP of the climb: succeeded, no verified, flagged" do
    # cheap low → escalates; quality confident but produces NO author → final unmet.
    let(:cheap)   { ReqStub.new(tier: "cheap", confidence: 0.2, claims: []) }
    let(:quality) do
      ReqStub.new(tier: "quality", confidence: 0.95,
                  claims: [ { "key" => "advisor", "op" => "ADD", "value" => "Dr. Adviser" } ])
    end
    before { configure_policy!; route_tiers!(cheap: cheap, quality: quality) }

    it "finalizes succeeded but mints NO verified and flags required_unmet" do
      final = tend!
      expect(final.status).to eq("succeeded")
      expect(final.applied).to be(true)
      expect(final.reload.reconciliation["required_unmet"]).to be(true)
      # advisor would be 'verified' at quality conf 0.95, but the unmet required key
      # bars verification for this visit — it stays draft.
      advisor = widget.enliterator_claims.live.find_by(key: "advisor")
      expect(advisor&.status).to eq("draft")
    end
  end

  describe "max_promotions bounds the climb even when required is unmet" do
    let(:cheap)   { ReqStub.new(tier: "cheap", confidence: 0.95, claims: [ { "key" => "advisor", "op" => "ADD", "value" => "A" } ]) }
    let(:quality) { ReqStub.new(tier: "quality", confidence: 0.95, claims: []) }
    before { configure_policy!(max_promotions: 0); route_tiers!(cheap: cheap, quality: quality) }

    it "does not climb past the bound; flags the single cheap visit" do
      tend!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(0)
      expect(widget.enliterator_visits.last.reload.reconciliation["required_unmet"]).to be(true)
    end
  end

  describe "byte-identical when the stream declares no required keys" do
    it "writes a reconciliation with NO required_unmet key" do
      policy = Enliterator::Staffing::Policy.new do
        stream :summary, tier: "cheap", keys: { summary: "One abstract." }
        ladder [ "cheap", "quality" ]
        verify_floor "quality"
      end
      Enliterator.configure { |c| c.staffing = policy }
      cheap = ReqStub.new(tier: "cheap", confidence: 0.95,
                          claims: [ { "key" => "summary", "op" => "ADD", "value" => "An abstract." } ])
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)

      Enliterator::Tending::Visitor.new(widget, stream: "summary", embedder: embedder).call
      recon = widget.enliterator_visits.last.reload.reconciliation
      expect(recon.key?("required_unmet")).to be(false)
    end
  end
end
