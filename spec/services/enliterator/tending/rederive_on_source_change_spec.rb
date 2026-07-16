# frozen_string_literal: true

require "rails_helper"

# v0.59 — re-derive on source change.
#
# When config.rederive_on_source_change is ON and a re-tend was scheduled by a
# SOURCE CHANGE (Visit.reason "source_change"), the Visitor threads
# `source_changed: true` into #tend, which SWAPS the "Understanding must COMPOUND /
# don't discard prior understanding" clause for a RE-DERIVE instruction. Flag off,
# or any other reason, omits the kwarg entirely ⇒ byte-identical prompt (rule 1).
RSpec.describe "Enliterator re-derive on source change (v0.59)" do
  # ---- the prompt swap (Base#system_for → build_system) --------------------
  describe "the prompt swap" do
    # Any Base subclass exposes the shared public #system_for; Null is simplest.
    let(:base) { Enliterator::Adapters::LLM::Null.new }

    it "source_changed:false is byte-identical to the default and keeps the COMPOUND clause" do
      default = base.system_for(nil)
      off     = base.system_for(nil, source_changed: false)

      expect(off).to eq(default)
      expect(off).to include("Understanding must COMPOUND")
      expect(off).not_to match(/SOURCE TEXT HAS CHANGED/)
      # the op contract + schema instruction survive
      expect(off).to include("- NOOP")
      expect(off).to include("Return ONLY structured output")
    end

    it "source_changed:true SWAPS in the re-derive clause and drops COMPOUND, keeping the op contract" do
      on = base.system_for(nil, source_changed: true)

      expect(on).to match(/SOURCE TEXT HAS CHANGED/)
      expect(on).to match(/re-derive each claim/i)
      expect(on).to match(/VERIFY against the current text/i)
      expect(on).not_to include("Understanding must COMPOUND")
      # the reconcile ops + structured-output instruction are unchanged
      expect(on).to include("- ADD")
      expect(on).to include("- NOOP")
      expect(on).to include("Return ONLY structured output")
    end

    it "re-derives even for a NO-contract facet (the swap precedes the contract early-return)" do
      expect(base.system_for(nil, source_changed: true)).to match(/SOURCE TEXT HAS CHANGED/)
    end

    it "re-derives AND keeps the controlled-vocabulary block for a contracted facet" do
      out = base.system_for({ summary: "One-line summary." }, source_changed: true)
      expect(out).to match(/SOURCE TEXT HAS CHANGED/)
      expect(out).to include("CONTROLLED VOCABULARY")
    end
  end

  # ---- the Visitor threading + functional end-to-end ----------------------
  describe "the Visitor threads source_changed only on a source-change re-tend under the flag" do
    # Sentinel default distinguishes "kwarg omitted" from "passed". Simulates the
    # model re-deriving: it emits UPDATE when source_changed is true, else NOOP —
    # so the functional test can watch the op flow through reconcile.
    class RederiveStubLLM
      Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
      UNSET  = :__source_changed_unset__

      attr_reader :captured

      def initialize
        @captured = []
      end

      def model_id
        "model-cheap"
      end

      def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, source_changed: UNSET)
        @captured << source_changed
        op = (source_changed == true) ? "UPDATE" : "NOOP"
        Result.new(
          parsed: {
            "claims" => [ { "key" => "summary", "value" => "fresh", "op" => op, "confidence" => 0.95 } ],
            "confidence" => 0.95
          },
          raw:    {},
          tokens: { "input" => 3, "output" => 1, "total" => 4 }
        )
      end
    end

    let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
    let(:stub)     { RederiveStubLLM.new }
    let(:widget)   { Widget.create!(title: "Chapter", body: "contingent local event") }

    before do
      policy = Enliterator::Staffing::Policy.new do
        assign :summary, tier: "cheap"   # unconstrained facet ⇒ no contract kwarg
        ladder [ "cheap" ]
        verify_floor "cheap"
      end
      Enliterator.configure { |c| c.staffing = policy }
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
    end

    def tend!(reason:)
      Enliterator::Tending::Visitor.new(widget, facet: "summary", embedder: embedder, reason: reason).call
    end

    it "flag OFF: never threads source_changed, even on a source_change visit" do
      tend!(reason: "source_change")
      expect(stub.captured).to eq([ RederiveStubLLM::UNSET ])
    end

    it "flag ON + reason 'source_change': threads source_changed: true" do
      Enliterator.configuration.rederive_on_source_change = true
      tend!(reason: "source_change")
      expect(stub.captured).to eq([ true ])
    end

    it "flag ON but a DIFFERENT reason (frontier): omits the kwarg" do
      Enliterator.configuration.rederive_on_source_change = true
      tend!(reason: "frontier")
      expect(stub.captured).to eq([ RederiveStubLLM::UNSET ])
    end

    it "flag ON but reason nil (a manual/legacy tend): omits the kwarg" do
      Enliterator.configuration.rederive_on_source_change = true
      tend!(reason: nil)
      expect(stub.captured).to eq([ RederiveStubLLM::UNSET ])
    end

    it "functional: under the flag, a source-change visit re-derives — the stale live claim is superseded" do
      Enliterator.configuration.rederive_on_source_change = true
      # the inherited 'fresh-but-wrong' predecessor: a prior live claim
      widget.enliterator_claims.create!(
        key: "summary", value: "stale (improbable local event)", status: "verified",
        attributed_to: "host", confidence: 1.0
      )

      tend!(reason: "source_change")

      live = widget.enliterator_claims.live.find_by(key: "summary")
      expect(stub.captured).to eq([ true ])       # the re-derive signal was sent
      expect(live.value).to eq("fresh")           # the UPDATE superseded the stale claim
      expect(widget.enliterator_claims.where(key: "summary", status: "superseded").count).to eq(1)
    end
  end
end
