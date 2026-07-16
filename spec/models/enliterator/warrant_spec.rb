# frozen_string_literal: true

require "rails_helper"

# v0.60 — split reconcile-status from audit-status (warrant).
#
# `verified` used to be minted by a pure CONFIDENCE gate at tend time — never an
# audit. Under config.audit_warrant a MODEL self-confident claim is minted `asserted`
# instead; `verified` is reserved for a human. Every claim exposes a derived `warrant`
# combining the reconcile-status with the latest instrument audit verdict (the
# canonical Audit.effective_verdict_pairs) and human authorship. Flag off ⇒ the model
# still mints `verified`, `warrant` is never surfaced, `to_state` is unchanged.
RSpec.describe "Enliterator claim warrant (v0.60)" do
  let(:widget) { Widget.create!(title: "W", body: "b") }

  def claim!(status:, locked: false, attributed_to: "cheap:model-x")
    widget.enliterator_claims.create!(
      key: "summary", value: "v", status: status, locked: locked,
      attributed_to: attributed_to, confidence: 0.9
    )
  end

  def audit!(claim, source:, verdict:, at:)
    Enliterator::Audit.create!(claim: claim, source: source, verdict: verdict,
                               auditor: "t", created_at: at)
  end

  describe "STATUSES + the live scope" do
    it "includes 'asserted' and treats it as live (not superseded)" do
      expect(Enliterator::Claim::STATUSES).to include("asserted")
      c = claim!(status: "asserted")
      expect(widget.enliterator_claims.live).to include(c)
    end
  end

  describe "#warrant — reconcile-status stands when unaudited" do
    it "asserted → asserted"     do expect(claim!(status: "asserted").warrant).to eq("asserted") end
    it "draft → draft"           do expect(claim!(status: "draft").warrant).to eq("draft") end
    it "superseded → superseded" do expect(claim!(status: "superseded").warrant).to eq("superseded") end

    it "a host seed (verified, locked, attributed to host) → verified — not human_verified" do
      expect(claim!(status: "verified", locked: true, attributed_to: "host").warrant).to eq("verified")
    end

    it "a locked HUMAN claim, unaudited → human_verified" do
      expect(claim!(status: "verified", locked: true, attributed_to: "human:jeremy").warrant).to eq("human_verified")
    end
  end

  describe "#warrant — the audit dimension outranks the reconcile-status" do
    it "examiner supported → examiner_supported" do
      c = claim!(status: "asserted"); audit!(c, source: "examiner", verdict: "supported", at: 1.hour.ago)
      expect(c.warrant).to eq("examiner_supported")
    end

    it "examiner unsupported/contradicted → contradicted" do
      c = claim!(status: "asserted"); audit!(c, source: "examiner", verdict: "contradicted", at: 1.hour.ago)
      d = claim!(status: "asserted"); audit!(d, source: "examiner", verdict: "unsupported", at: 1.hour.ago)
      expect(c.warrant).to eq("contradicted")
      expect(d.warrant).to eq("contradicted")
    end

    it "human supported → human_verified" do
      c = claim!(status: "asserted"); audit!(c, source: "human", verdict: "supported", at: 1.hour.ago)
      expect(c.warrant).to eq("human_verified")
    end

    it "unverifiable carries no warrant — falls through to the reconcile-status" do
      c = claim!(status: "asserted"); audit!(c, source: "examiner", verdict: "unverifiable", at: 1.hour.ago)
      expect(c.warrant).to eq("asserted")
    end

    it "a later HUMAN verdict outranks an earlier examiner one" do
      c = claim!(status: "asserted")
      audit!(c, source: "examiner", verdict: "supported",   at: 2.hours.ago)
      audit!(c, source: "human",    verdict: "contradicted", at: 1.hour.ago)
      expect(c.warrant).to eq("contradicted")
    end

    it "a standing human verdict is NOT overturned by a later examiner (the anchor holds)" do
      c = claim!(status: "asserted")
      audit!(c, source: "human",    verdict: "supported",   at: 2.hours.ago)
      audit!(c, source: "examiner", verdict: "contradicted", at: 1.hour.ago)
      expect(c.warrant).to eq("human_verified")
    end

    it "an AGENT flag carries no warrant weight (instrument-scoped)" do
      c = claim!(status: "asserted"); audit!(c, source: "agent", verdict: "contradicted", at: 1.hour.ago)
      expect(c.warrant).to eq("asserted")
    end
  end

  describe "Audit.effective_verdict_pairs (the canonical precedence)" do
    it "returns {} for empty ids" do
      expect(Enliterator::Audit.effective_verdict_pairs([])).to eq({})
    end

    it "is id-keyed, batched, latest-wins, human-outranks-examiner, agent-blind" do
      c1 = claim!(status: "asserted"); c2 = claim!(status: "asserted")
      audit!(c1, source: "examiner", verdict: "supported",   at: 2.hours.ago)
      audit!(c1, source: "human",    verdict: "contradicted", at: 1.hour.ago)
      audit!(c2, source: "examiner", verdict: "unsupported", at: 1.hour.ago)
      audit!(c2, source: "agent",    verdict: "supported",   at: 1.minute.ago) # ignored

      pairs = Enliterator::Audit.effective_verdict_pairs([ c1.id, c2.id ])
      expect(pairs[c1.id]).to eq([ "human", "contradicted" ])
      expect(pairs[c2.id]).to eq([ "examiner", "unsupported" ])
    end
  end

  describe "to_state gating (byte-identical when off)" do
    it "flag OFF: to_state carries NO :warrant key" do
      expect(claim!(status: "verified").to_state).not_to have_key(:warrant)
    end

    it "flag ON: to_state carries the honest warrant" do
      Enliterator.configuration.audit_warrant = true
      expect(claim!(status: "asserted").to_state[:warrant]).to eq("asserted")
    end
  end

  describe "the mint — config.audit_warrant decides asserted vs verified" do
    class MintStubLLM
      Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
      def model_id = "model-cheap"

      def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil)
        Result.new(
          parsed: {
            "claims" => [ { "key" => "summary", "value" => "x", "op" => "ADD", "confidence" => 0.95 } ],
            "confidence" => 0.95
          },
          raw: {}, tokens: { "total" => 1 }
        )
      end
    end

    let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
    let(:stub)     { MintStubLLM.new }

    before do
      policy = Enliterator::Staffing::Policy.new do
        assign :summary, tier: "cheap"
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
      Enliterator.configure { |c| c.staffing = policy }
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
    end

    def tend!
      Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
    end

    it "flag OFF: a model self-confident claim is minted 'verified' (byte-identical)" do
      tend!
      expect(widget.enliterator_claims.live.find_by(key: "summary").status).to eq("verified")
    end

    it "flag ON: it is minted 'asserted', and its warrant reads 'asserted'" do
      Enliterator.configuration.audit_warrant = true
      tend!
      c = widget.enliterator_claims.live.find_by(key: "summary")
      expect(c.status).to eq("asserted")
      expect(c.warrant).to eq("asserted")
    end
  end
end
