# frozen_string_literal: true

require "rails_helper"

# Stage 1 (read-time warrant accrual) — the Visitor's threading of `candidates:`.
#
# When config.read_time_warrant is ON and the facet has a contract, the Visitor
# resolves the CANDIDATE vocabulary ONCE per record (Vocabulary.candidates_for) and
# threads it into EVERY tier visit's #tend. When the flag is OFF — or ON but the
# facet has no contract — `candidates_for` is never even called. When it IS called
# but returns nil (no pending), the `!candidates.nil?` gate omits the kwarg. In all
# three "no-candidates" cases the adapter call is byte-identical to v0.3: no
# `:candidates` key reaches #tend. The flag default is nil (reset each example), so
# flag-OFF is the suite baseline.
RSpec.describe "Enliterator::Tending::Visitor read-time warrant threading (stage 1)" do
  # A per-tier recording stub. Its #tend DECLARES `candidates:` (so the Visitor's
  # adapter_accepts_kwarg? gate WILL pass it) with a SENTINEL default — so the spec
  # can tell "kwarg omitted" (UNSET) apart from "passed nil". Records every
  # candidates value it was handed, across escalation.
  class WarrantStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    UNSET  = :__candidates_unset__

    attr_reader :tier, :captured_candidates, :calls

    def initialize(tier:, confidence:)
      @tier                = tier
      @confidence          = confidence
      @captured_candidates = []
      @calls               = 0
    end

    def model_id
      "model-#{@tier}"
    end

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, candidates: UNSET)
      @calls += 1
      @captured_candidates << candidates
      Result.new(
        parsed: { "claims" => [], "confidence" => @confidence },
        raw:    { "tier" => @tier },
        tokens: { "input" => 5, "output" => 2, "total" => 7 }
      )
    end
  end

  let(:widget)   { Widget.create!(title: "Thesis", body: "A record worth governing.") }
  let(:w2)       { Widget.create!(title: "Other", body: "y") }
  let(:w3)       { Widget.create!(title: "Third", body: "z") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # A constrained facet (terms ⇒ a contract exists ⇒ candidates are meaningful).
  def configure_contract_facet!(max_promotions: 1)
    policy = Enliterator::Staffing::Policy.new do
      facet :metadata, tier: "cheap", terms: {
        author: "Who authored the work.",
        date:   "When the work was created."
      }
      ladder [ "cheap", "quality" ]
      verify_floor "cheap"
      max_promotions max_promotions
    end
    Enliterator.configure { |c| c.staffing = policy }
  end

  def route!(cheap:, quality: nil)
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality) if quality
  end

  def propose!(record, key, context: nil)
    Enliterator::Suggestion.create!(tendable: record, facet: "metadata", proposed_key: key,
                                    rationale: "names the #{key}", example_value: "e",
                                    status: "pending", context: context)
  end

  def tend!
    Enliterator::Tending::Visitor.new(widget, facet: "metadata", embedder: embedder).call
  end

  describe "flag OFF (default) — byte-identical, no candidates kwarg" do
    let(:cheap) { WarrantStubLLM.new(tier: "cheap", confidence: 0.95) }

    before do
      configure_contract_facet!
      route!(cheap: cheap)
      # A real candidate field EXISTS (two distinct records warrant 'funder') —
      # flag-off must ignore it entirely.
      propose!(w2, "funder")
      propose!(w3, "funder")
    end

    it "never threads :candidates into #tend (kwarg omitted)" do
      tend!
      expect(cheap.captured_candidates).to eq([ WarrantStubLLM::UNSET ])
    end

    it "does not even call Vocabulary.candidates_for" do
      allow(Enliterator::Vocabulary).to receive(:candidates_for).and_call_original
      tend!
      expect(Enliterator::Vocabulary).not_to have_received(:candidates_for)
    end
  end

  describe "flag ON + candidates present — resolved once, threaded up the ladder" do
    let(:cheap)   { WarrantStubLLM.new(tier: "cheap",   confidence: 0.1) }  # escalates
    let(:quality) { WarrantStubLLM.new(tier: "quality", confidence: 0.95) }

    before do
      configure_contract_facet!(max_promotions: 1)
      route!(cheap: cheap, quality: quality)
      Enliterator.configuration.read_time_warrant = true
      propose!(w2, "funder")
      propose!(w3, "funder")  # 2 distinct records ⇒ warranted candidate
    end

    it "resolves the candidate vocabulary exactly once per record (not per tier visit)" do
      allow(Enliterator::Vocabulary).to receive(:candidates_for).and_call_original
      tend!
      expect(Enliterator::Vocabulary).to have_received(:candidates_for).once
    end

    it "threads the SAME candidate list into every tier visit (cheap AND the escalated quality)" do
      tend!
      expect(cheap.calls).to eq(1)
      expect(quality.calls).to eq(1)

      cheap_cands   = cheap.captured_candidates.first
      quality_cands = quality.captured_candidates.first

      expect(cheap_cands).to be_an(Array)
      expect(cheap_cands.map { |g| g[:proposed_key] }).to include("funder")
      # Computed once, handed unchanged to the senior tier.
      expect(quality_cands).to eq(cheap_cands)
    end
  end

  describe "flag ON but no pending candidates — candidates_for returns nil ⇒ kwarg omitted" do
    let(:cheap) { WarrantStubLLM.new(tier: "cheap", confidence: 0.95) }

    before do
      configure_contract_facet!
      route!(cheap: cheap)
      Enliterator.configuration.read_time_warrant = true
      # NO suggestions proposed ⇒ candidates_for returns nil.
    end

    it "calls candidates_for (the gate is live) but omits the kwarg when it is nil" do
      allow(Enliterator::Vocabulary).to receive(:candidates_for).and_call_original
      tend!
      expect(Enliterator::Vocabulary).to have_received(:candidates_for).once
      expect(cheap.captured_candidates).to eq([ WarrantStubLLM::UNSET ])
    end
  end

  describe "flag ON but the facet is UNCONSTRAINED (no contract) — candidates_for skipped" do
    let(:cheap) { WarrantStubLLM.new(tier: "cheap", confidence: 0.95) }

    before do
      policy = Enliterator::Staffing::Policy.new do
        assign :metadata, tier: "cheap"   # NO terms ⇒ no contract
        ladder [ "cheap", "quality" ]
        verify_floor "cheap"
      end
      Enliterator.configure { |c| c.staffing = policy }
      route!(cheap: cheap)
      Enliterator.configuration.read_time_warrant = true
      propose!(w2, "funder")  # candidates exist in the table, but no contract to gate under
    end

    it "skips candidates_for entirely (no contract ⇒ nothing to affirm) and omits the kwarg" do
      allow(Enliterator::Vocabulary).to receive(:candidates_for).and_call_original
      tend!
      expect(Enliterator::Vocabulary).not_to have_received(:candidates_for)
      expect(cheap.captured_candidates).to eq([ WarrantStubLLM::UNSET ])
    end
  end
end
