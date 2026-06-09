# frozen_string_literal: true

require "rails_helper"

# v0.3 §5 — locked-claim import. `assert_claim!` lets a host seed structured
# metadata (e.g. an authoritative `published_at`) as a first-class, LOCKED,
# verified Claim the LLM never derives. reconcile already NOOPs locked claims on
# UPDATE, so tending will not overwrite a host-asserted truth. The method is
# idempotent: a second call updates the same live claim in place — never a dup.
RSpec.describe Enliterator::Tendable, "#assert_claim!" do
  # A staffing-path stub that ALWAYS proposes an UPDATE to "author" — used to prove
  # the locked claim is never auto-superseded by tending.
  class AssertUpdateStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    def model_id
      "model-cheap"
    end

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil)
      parsed = {
        "claims" => [
          { "key" => "author", "op" => "UPDATE", "value" => "LLM-derived (should not apply)", "confidence" => 0.99 }
        ],
        "confidence" => 0.99
      }
      Result.new(parsed: parsed, raw: {}, tokens: {})
    end
  end

  let(:widget) { Widget.create!(title: "Thesis", body: "A governed record.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  describe "seeding a locked verified claim" do
    it "creates a locked, verified claim attributed to the host" do
      claim = widget.assert_claim!(key: "author", value: "Ada Lovelace")

      expect(claim).to be_present
      expect(claim.key).to eq("author")
      expect(claim.value).to eq("Ada Lovelace")
      expect(claim.locked).to be(true)
      expect(claim.status).to eq("verified")
      expect(claim.attributed_to).to eq("host")
    end

    it "creates exactly one live claim and creates NO visit (import, not tending)" do
      expect { widget.assert_claim!(key: "author", value: "Ada Lovelace") }
        .to change { widget.enliterator_claims.live.where(key: "author").count }.by(1)
        .and change { widget.enliterator_visits.count }.by(0)
    end
  end

  describe "idempotency" do
    it "updates the same live claim in place on a second call — no duplicate" do
      first  = widget.assert_claim!(key: "author", value: "Ada Lovelace")
      second = widget.assert_claim!(key: "author", value: "Ada Lovelace")

      expect(second.id).to eq(first.id)
      expect(widget.enliterator_claims.where(key: "author").count).to eq(1)
    end

    it "applies a changed value to the same live claim (still one row)" do
      first   = widget.assert_claim!(key: "author", value: "A. Lovelace")
      updated = widget.assert_claim!(key: "author", value: "Ada Lovelace")

      expect(updated.id).to eq(first.id)
      expect(updated.reload.value).to eq("Ada Lovelace")
      expect(widget.enliterator_claims.where(key: "author").count).to eq(1)
    end
  end

  describe "tending NOOPs a host-locked claim (the well stays unpoisoned)" do
    before do
      policy = Enliterator::Staffing::Policy.new do
        assign :metadata, tier: "cheap"
        ladder ["cheap"]
        verify_floor "cheap"
      end
      Enliterator.configure { |c| c.staffing = policy }
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(AssertUpdateStubLLM.new)
    end

    it "leaves the locked claim live and unchanged after a tend that proposes UPDATE" do
      locked = widget.assert_claim!(key: "author", value: "Ada Lovelace")

      visit = Enliterator::Tending::Visitor.new(widget, facet: "metadata", embedder: embedder).call

      locked.reload
      expect(locked.value).to eq("Ada Lovelace")
      expect(locked.locked).to be(true)
      expect(locked.status).to eq("verified")
      expect(locked.superseded_by_id).to be_nil

      # No replacement claim was minted — only the host's anchor remains live.
      expect(widget.enliterator_claims.live.where(key: "author").count).to eq(1)
      expect(widget.enliterator_claims.live.where(key: "author").first.id).to eq(locked.id)

      # The UPDATE was recorded as a NOOP on the finalized visit.
      expect(visit.reconciliation["noop"]).to include("author")
      expect(visit.reconciliation["updated"]).to eq([])
    end
  end
end
