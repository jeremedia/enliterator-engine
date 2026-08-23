# frozen_string_literal: true

require "rails_helper"

# v0.72.5 — the abstention verdict: coherent examiner semantics for empty claims.
#
# An empty-valued claim is a claim of ABSENCE ("the source provides nothing for
# this key"). Before this, the examiner had no reading of correct abstention and
# coin-flipped: 91 empty supersedes claims → 42 supported / 46 unsupported /
# 3 contradicted, with IDENTICAL rationales under opposite labels. The analysis
# was right in 88 of 91; only the label was arbitrary.
#
# Three coherent branches: supported (nothing there — ONLY on a complete
# source) / contradicted (the source names one — provable from any fragment) /
# unverifiable (truncated + names none: an absence claim asserts something
# about the WHOLE document). `unsupported` is incoherent and coerced.
RSpec.describe "v0.72.5 absence verdict (Audit::Examiner)" do
  class AbsenceExaminerLLMStub
    attr_reader :last_messages
    def initialize(verdict: "supported")
      @verdict = verdict
    end
    def model_id = "stub-quality"
    def decide(messages:, schema:, tool_name:, tags: [])
      @last_messages = messages
      { "verdict" => @verdict, "rationale" => "r", "confidence" => 0.9 }
    end
  end

  def verdict_for(stub, value:, truncated: nil)
    Enliterator::Audit::Examiner.new(llm: stub).verdict_for(
      facet: "legal_relations", key: "supersedes", value: value,
      source: "This order concerns procurement. It changes nothing prior.",
      truncated: truncated
    )
  end

  describe "the prompt swap" do
    it "swaps in the absence block for a blank value — SWAP, not append (the two contradict)" do
      stub = AbsenceExaminerLLMStub.new
      verdict_for(stub, value: "", truncated: false)
      system = stub.last_messages.first[:content]
      expect(system).to include("claim of ABSENCE")
      expect(system).to include("NEVER render unsupported")
      expect(system).not_to include("NEVER grounds")          # the standard block is GONE
      user = stub.last_messages.last[:content]
      expect(user).to include("(empty — a claim of ABSENCE")
    end

    it "treats [] and {} as absence too — the reader loop's own blank definition, shared" do
      stub = AbsenceExaminerLLMStub.new
      verdict_for(stub, value: [], truncated: false)
      expect(stub.last_messages.first[:content]).to include("claim of ABSENCE")
    end

    it "GOLDEN: a non-blank call is byte-identical to the v0.70 prompt, whatever truncated says" do
      baseline = AbsenceExaminerLLMStub.new
      verdict_for(baseline, value: "EO 12036")
      [ true, false, nil ].each do |t|
        stub = AbsenceExaminerLLMStub.new
        verdict_for(stub, value: "EO 12036", truncated: t)
        expect(stub.last_messages).to eq(baseline.last_messages)
      end
      expect(baseline.last_messages.first[:content]).to include("NEVER grounds")
    end

    it "names the availability of `supported` from the truncation the caller vouched" do
      stub = AbsenceExaminerLLMStub.new
      verdict_for(stub, value: "", truncated: false)
      expect(stub.last_messages.first[:content]).to include("COMPLETE source, so this verdict is available")

      verdict_for(stub, value: "", truncated: true)
      expect(stub.last_messages.first[:content]).to include("TRUNCATED")

      verdict_for(stub, value: "", truncated: nil)
      expect(stub.last_messages.first[:content]).to include("UNKNOWN")
    end
  end

  describe "the SYMMETRIC coercion (instruction-only enforcement leaves both directions reachable)" do
    it "coerces unsupported → unverifiable on a blank call (incoherent for absence)" do
      out = verdict_for(AbsenceExaminerLLMStub.new(verdict: "unsupported"), value: "", truncated: false)
      expect(out[:verdict]).to eq("unverifiable")
    end

    it "coerces supported → unverifiable when the caller never vouched completeness" do
      # The doc-701079 shape: truncated source, no change language — confirming
      # the absence from a fragment would be the coin flip rebuilt.
      expect(verdict_for(AbsenceExaminerLLMStub.new(verdict: "supported"), value: "", truncated: true)[:verdict])
        .to eq("unverifiable")
      expect(verdict_for(AbsenceExaminerLLMStub.new(verdict: "supported"), value: "", truncated: nil)[:verdict])
        .to eq("unverifiable")
    end

    it "lets supported STAND on a complete source, and contradicted stand from any fragment" do
      expect(verdict_for(AbsenceExaminerLLMStub.new(verdict: "supported"), value: "", truncated: false)[:verdict])
        .to eq("supported")
      expect(verdict_for(AbsenceExaminerLLMStub.new(verdict: "contradicted"), value: "", truncated: true)[:verdict])
        .to eq("contradicted")
    end

    it "never coerces a NON-blank claim's verdicts" do
      expect(verdict_for(AbsenceExaminerLLMStub.new(verdict: "unsupported"), value: "EO 1", truncated: true)[:verdict])
        .to eq("unsupported")
      expect(verdict_for(AbsenceExaminerLLMStub.new(verdict: "supported"), value: "EO 1", truncated: nil)[:verdict])
        .to eq("supported")
    end
  end

  describe "examine! threads its own truncation" do
    it "passes the computed flag through, so a standing audit of an empty claim on a truncated source cannot mint supported" do
      Enliterator.configuration.audit_source_chars = 30
      w = Widget.create!(title: "w", body: "X" * 200)   # over the ceiling → truncated
      visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      empty = w.enliterator_claims.create!(key: "summary", value: "", status: "draft", tier: "cheap", visit: visit)

      audit = Enliterator::Audit::Examiner.new(llm: AbsenceExaminerLLMStub.new(verdict: "supported")).examine!(empty)
      expect(audit.source_truncated).to be(true)
      expect(audit.verdict).to eq("unverifiable")
    end
  end

  describe "Audit.accuracy abstained: count (the standing instrument sees the split)" do
    it "counts audits of empty claims per cell, additively, beside the untouched rate" do
      w = Widget.create!(title: "w", body: "b")
      visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
      filled = w.enliterator_claims.create!(key: "k1", value: "v", status: "draft", tier: "cheap", visit: visit)
      empty  = w.enliterator_claims.create!(key: "k2", value: "", status: "draft", tier: "cheap", visit: visit)
      Enliterator::Audit.create!(claim: filled, verdict: "supported", source: "examiner")
      Enliterator::Audit.create!(claim: empty,  verdict: "supported", source: "examiner")

      cell = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(cell[:abstained]).to eq(1)
      expect(cell[:supported_rate]).to eq(1.0)   # the pooled process record, untouched
    end
  end
end
