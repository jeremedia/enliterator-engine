# frozen_string_literal: true

require "rails_helper"

# v0.18 phase 1 — the audit row + the human correction write path.
RSpec.describe "Enliterator::Audit + Tendable#correct_claim! (v0.18)" do
  let(:widget) { Widget.create!(title: "T", body: "a body worth auditing") }
  let(:claim) do
    widget.enliterator_claims.create!(key: "summary", value: "wrong take", status: "draft",
                                      visit: visit, tier: "cheap", confidence: 1.0)
  end
  let(:visit) do
    widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
  end

  describe Enliterator::Audit do
    it "validates verdict and source" do
      expect(Enliterator::Audit.new(claim: claim, verdict: "supported", source: "examiner")).to be_valid
      expect(Enliterator::Audit.new(claim: claim, verdict: "maybe", source: "examiner")).not_to be_valid
      expect(Enliterator::Audit.new(claim: claim, verdict: "supported", source: "oracle")).not_to be_valid
    end

    it "knows the supported/defective binary (unverifiable is neither)" do
      expect(Enliterator::Audit.new(verdict: "contradicted")).to be_defective
      expect(Enliterator::Audit.new(verdict: "unsupported")).to be_defective
      expect(Enliterator::Audit.new(verdict: "supported")).not_to be_defective
      expect(Enliterator::Audit.new(verdict: "unverifiable")).not_to be_defective
    end
  end

  describe "#correct_claim!" do
    it "mints a locked, verified, human-attributed claim in the SAME context and supersedes the old" do
      ctx = Enliterator::Context.create!(key: "crs-reports", name: "CRS")
      scoped = widget.enliterator_claims.create!(key: "issue_for_congress", value: "wrong",
                                                 status: "draft", visit: visit, context: ctx)

      fresh = widget.correct_claim!(scoped, value: "the corrected issue", note: "amber")

      expect(fresh.locked).to be(true)
      expect(fresh.status).to eq("verified")
      expect(fresh.visit_id).to be_nil
      expect(fresh.context_id).to eq(ctx.id)
      expect(fresh.attributed_to).to eq("human:amber")
      expect(fresh.derived_from).to eq([ { "type" => "claim", "id" => scoped.id } ])
      expect(scoped.reload.status).to eq("superseded")
      expect(scoped.superseded_by_id).to eq(fresh.id)
      expect(widget.enliterator_claims.live.find_by(key: "issue_for_congress")).to eq(fresh)
    end

    it "the correction survives the next tend — reconcile NOOPs the curator anchor" do
      fresh = widget.correct_claim!(claim, value: "the human truth")

      v2 = widget.enliterator_visits.create!(facet: "summary", status: "running", applied: true, tier: "cheap")
      recon = Enliterator::Tending::Visitor.new(widget, facet: "summary", llm: nil)
                .reconcile!([ { "key" => "summary", "op" => "UPDATE", "value" => "model tries again" } ],
                            v2, attributed_to: "cheap:m", tier: "cheap", may_verify: false)

      expect(recon[:noop]).to eq([ "summary" ])
      expect(widget.enliterator_claims.live.find_by(key: "summary")).to eq(fresh)
      expect(fresh.reload.value).to eq("the human truth")
    end

    it "guards liveness — a claim superseded since examination raises, the chain stays intact" do
      replacement = widget.enliterator_claims.create!(key: "summary", value: "re-tended", status: "draft")
      claim.supersede!(replacement)

      expect {
        widget.correct_claim!(claim, value: "too late")
      }.to raise_error(Enliterator::Claim::AlreadySuperseded, /superseded after examination/)
      expect(claim.reload.superseded_by_id).to eq(replacement.id)   # not clobbered
    end

    it "refuses a claim belonging to another record" do
      other = Widget.create!(title: "other", body: "b")
      expect { other.correct_claim!(claim, value: "x") }.to raise_error(ArgumentError)
    end
  end
end
