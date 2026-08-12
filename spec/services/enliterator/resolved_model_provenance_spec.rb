# frozen_string_literal: true

require "rails_helper"

# v0.68 — the CONSUMERS of resolved-model provenance.
#
# The adapter contract is proven in gateway_resolved_model_spec.rb. This proves
# the two places the resolved model has to LAND to be worth anything: the visit
# row (what tended this record) and the audit row (what examined this claim).
#
# The distinction that matters: `tier` is the alias we ROUTED by, `model` is the
# backend that ANSWERED. They were identical strings until a gateway alias was
# repointed to a different vendor underneath a running collection — at which
# point every row on both sides read the same and the record could not tell you
# which model made which claim.
RSpec.describe "v0.68 resolved-model provenance (consumers)" do
  let(:widget)   { Widget.create!(title: "T", body: "b") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Post-v0.68 adapter: its Result carries the resolved backend.
  class ReportingStub
    Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
    def model_id = "enliterator-quality"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {}, tokens: {},
                 model: "bedrock_mantle/openai.gpt-5.6-terra")
    end
  end

  # Pre-v0.68 adapter: Result has no :model member at all. Must stay byte-identical.
  class SilentStub
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    def model_id = "enliterator-quality"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      Result.new(parsed: { "claims" => [], "confidence" => 0.9 }, raw: {}, tokens: {})
    end
  end

  def staff!
    Enliterator.configure do |c|
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :summary, tier: "enliterator-quality", terms: { summary: "An abstract." }
        ladder [ "enliterator-quality" ]
        verify_floor "enliterator-quality"
      end
    end
  end

  def tend_with(stub)
    staff!
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "enliterator-quality").and_return(stub)
    Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder).call
  end

  describe "the visit row" do
    it "records the RESOLVED backend in model and keeps the ALIAS in tier" do
      visit = tend_with(ReportingStub.new)
      expect(visit.reload.model).to eq("bedrock_mantle/openai.gpt-5.6-terra")
      expect(visit.tier).to eq("enliterator-quality")
    end

    it "keeps the alias in model when the adapter reports nothing (pre-v0.68)" do
      visit = tend_with(SilentStub.new)
      expect(visit.reload.model).to eq("enliterator-quality")
      expect(visit.tier).to eq("enliterator-quality")
    end

    it "makes a backend swap behind a stable alias VISIBLE across two visits" do
      first = tend_with(ReportingStub.new)

      swapped = Class.new(ReportingStub) do
        def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
          ReportingStub::Result.new(parsed: { "claims" => [], "confidence" => 0.9 },
                                    raw: {}, tokens: {}, model: "bedrock/anthropic.claude-opus-4-8")
        end
      end
      second = tend_with(swapped.new)

      # Same alias on both rows — the swap is invisible in `tier`, which is
      # exactly the failure v0.68 exists to close.
      expect(first.reload.tier).to eq(second.reload.tier)
      expect(first.model).not_to eq(second.model)
    end
  end

  describe "the audit row" do
    # Reports the resolved backend through the v0.68 meta out-param.
    class ReportingExaminerStub
      def model_id = "enliterator-quality"
      def decide(messages:, schema:, tool_name:, tags: [], meta: nil)
        meta[:model] = "bedrock_mantle/openai.gpt-5.6-sol" if meta.is_a?(Hash)
        { "verdict" => "supported", "rationale" => "the source says so", "confidence" => 0.9 }
      end
    end

    # Pre-v0.68 signature — no meta kwarg. The examiner must not pass one.
    class LegacyExaminerStub
      def model_id = "enliterator-quality"
      def decide(messages:, schema:, tool_name:, tags: [])
        { "verdict" => "supported", "rationale" => "ok", "confidence" => 0.9 }
      end
    end

    def claim!
      visit = widget.enliterator_visits.create!(
        facet: "summary", status: "succeeded", model: "enliterator-quality",
        tier: "enliterator-quality", started_at: Time.current, finished_at: Time.current
      )
      widget.enliterator_claims.create!(key: "summary", value: "a take",
                                        status: "draft", visit: visit, tier: "enliterator-quality")
    end

    # auditor is "<effective_tier>:<model>". The tier half comes from the audit
    # tier resolution (unconfigured here, so it is the default ladder's) — what
    # v0.68 changes is the MODEL half, so that is what these pin.
    it "stamps the RESOLVED backend as the model half" do
      audit = Enliterator::Audit::Examiner.new(llm: ReportingExaminerStub.new).examine!(claim!)
      expect(audit.auditor).to end_with(":bedrock_mantle/openai.gpt-5.6-sol")
    end

    it "falls back to the adapter's model_id for a pre-v0.68 adapter" do
      audit = Enliterator::Audit::Examiner.new(llm: LegacyExaminerStub.new).examine!(claim!)
      expect(audit.auditor).to end_with(":enliterator-quality")
    end
  end
end
