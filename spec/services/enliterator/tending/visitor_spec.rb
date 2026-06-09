# frozen_string_literal: true

require "rails_helper"

# THE compounding contract — literacy rung 5.
#
# This spec is the heart of the engine. It proves that understanding COMPOUNDS:
# each Visit reads the record's accumulated claims/visits and conditions the next.
# We drive the Visitor with a tiny stub LLM that records every `state:` it is
# handed, returns an ADD on its first call and an UPDATE on its second, and then
# assert the full provenance + reconciliation behavior — including the crucial
# claim that the SECOND call saw the FIRST call's claim in its state.
RSpec.describe Enliterator::Tending::Visitor do
  # A deterministic, network-free LLM adapter for the compounding test.
  #
  # - Conforms to the LLM contract: responds to #model_id and
  #   #tend(text:, facet:, state:, neighbors:) returning a Result-like object
  #   that responds to .parsed / .raw / .tokens.
  # - Captures EVERY `state:` it is given (in call order) so the spec can prove
  #   prior understanding flowed into the next visit.
  # - Call 1 => one ADD of key "summary" value "v1" (conf 0.6).
  # - Call 2 => one UPDATE of key "summary" value "v2" (conf 0.8).
  class CompoundingStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    attr_reader :calls, :captured_states

    def initialize
      @calls = 0
      @captured_states = []
    end

    def model_id
      "stub-compounding"
    end

    def tend(text:, facet:, state:, neighbors:)
      @calls += 1
      # Snapshot the compounding context exactly as the Visitor handed it over.
      @captured_states << state

      parsed =
        if @calls == 1
          {
            "claims" => [
              { "key" => "summary", "op" => "ADD", "value" => "v1", "confidence" => 0.6 }
            ],
            "confidence" => 0.6
          }
        else
          {
            "claims" => [
              { "key" => "summary", "op" => "UPDATE", "value" => "v2", "confidence" => 0.8 }
            ],
            "confidence" => 0.8
          }
        end

      Result.new(parsed: parsed, raw: { "stub" => true, "call" => @calls }, tokens: { "input" => 1, "output" => 1, "total" => 2 })
    end
  end

  # A stub that ALWAYS proposes an UPDATE to "summary" — used to prove a locked
  # claim is never auto-superseded.
  class AlwaysUpdateStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

    def model_id
      "stub-always-update"
    end

    def tend(text:, facet:, state:, neighbors:)
      parsed = {
        "claims" => [
          { "key" => "summary", "op" => "UPDATE", "value" => "should-not-apply", "confidence" => 0.9 }
        ],
        "confidence" => 0.9
      }
      Result.new(parsed: parsed, raw: {}, tokens: {})
    end
  end

  let(:widget) { Widget.create!(title: "Acme", body: "A widget worth understanding.") }
  # Null embedder keeps neighbor math network-free; the widget has no embedding,
  # so nearest_neighbors returns [] gracefully.
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  describe "compounding across two visits (the heart of the engine)" do
    let(:llm) { CompoundingStubLLM.new }

    # Run the Visitor twice over the same widget with the same stub instance, so
    # the second call sees the claim the first call produced.
    def tend_twice!
      visit1 = described_class.new(widget, facet: "summary", llm: llm, embedder: embedder).call
      visit2 = described_class.new(widget, facet: "summary", llm: llm, embedder: embedder).call
      [ visit1, visit2 ]
    end

    it "records two succeeded Visit rows" do
      visit1, visit2 = tend_twice!

      expect(widget.enliterator_visits.count).to eq(2)
      expect(visit1.status).to eq("succeeded")
      expect(visit2.status).to eq("succeeded")
      expect([ visit1.id, visit2.id ].uniq.length).to eq(2)
    end

    it "creates a draft 'summary' claim with value 'v1' after the first call" do
      described_class.new(widget, facet: "summary", llm: llm, embedder: embedder).call

      claim = widget.enliterator_claims.find_by(key: "summary")
      expect(claim).to be_present
      expect(claim.value).to eq("v1")
      expect(claim.status).to eq("draft")
      expect(claim.locked).to eq(false)
      expect(claim.confidence).to eq(0.6)
      expect(claim.attributed_to).to eq("stub-compounding")
      # Exactly one summary claim exists at this point.
      expect(widget.enliterator_claims.where(key: "summary").count).to eq(1)
    end

    it "supersedes the old claim and links derived_from to it after the second call" do
      tend_twice!

      claims = widget.enliterator_claims.where(key: "summary").order(:id).to_a
      expect(claims.length).to eq(2)

      old_claim, new_claim = claims

      # Old claim: superseded, points forward to the new one, no longer live.
      expect(old_claim.value).to eq("v1")
      expect(old_claim.status).to eq("superseded")
      expect(old_claim.superseded_by_id).to eq(new_claim.id)

      # New claim: the single live claim, value v2, provenance chained to the old.
      expect(new_claim.value).to eq("v2")
      expect(new_claim.status).to eq("draft")
      expect(new_claim.superseded_by_id).to be_nil

      live = widget.enliterator_claims.live.where(key: "summary").to_a
      expect(live.length).to eq(1)
      expect(live.first.id).to eq(new_claim.id)
      expect(live.first.value).to eq("v2")

      # prov:wasDerivedFrom references the old claim by id (jsonb => string keys).
      expect(new_claim.derived_from).to eq([ { "type" => "claim", "id" => old_claim.id } ])
    end

    it "writes the expected reconciliation hashes on each visit" do
      visit1, visit2 = tend_twice!

      expect(visit1.reconciliation).to eq(
        "added" => [ "summary" ], "updated" => [], "deleted" => [], "noop" => []
      )
      expect(visit2.reconciliation).to eq(
        "added" => [], "updated" => [ "summary" ], "deleted" => [], "noop" => []
      )
    end

    # The CRUCIAL assertion: the second visit must have seen the first visit's
    # claim in its `state`. This is what proves understanding compounds — the
    # prior visit literally conditioned the next one's input.
    it "feeds the first call's claim into the second call's state (PROOF of compounding)" do
      tend_twice!

      expect(llm.captured_states.length).to eq(2)

      first_state  = llm.captured_states[0]
      second_state = llm.captured_states[1]

      # First call saw an empty claim set — nothing had been learned yet.
      expect(first_state[:claims]).to eq([])

      # Second call saw a NON-EMPTY claim set containing the "summary" claim the
      # first visit produced (value "v1"). The loop closed.
      second_claims = second_state[:claims]
      expect(second_claims).not_to be_empty
      summary_state = second_claims.find { |c| c[:key] == "summary" }
      expect(summary_state).to be_present
      expect(summary_state[:value]).to eq("v1")
      expect(summary_state[:status]).to eq("draft")
      expect(summary_state[:locked]).to eq(false)
    end

    it "stamps each succeeded visit with model, prompt version, and confidence" do
      visit1, visit2 = tend_twice!

      expect(visit1.model).to eq("stub-compounding")
      expect(visit1.prompt_version).to eq(Enliterator::Tending::Visitor::PROMPT_VERSION)
      expect(visit1.confidence).to eq(0.6)

      expect(visit2.confidence).to eq(0.8)
      # The finalized visit records the claim keys it read for context. The second
      # visit read the "summary" claim the first produced.
      expect(visit2.input_refs["claim_keys"]).to include("summary")
    end
  end

  describe "a locked claim is protected from UPDATE (NOOP, never superseded)" do
    let(:llm) { AlwaysUpdateStubLLM.new }

    it "leaves the locked claim live and unchanged, recording the op as a noop" do
      # Curator anchor: a locked, live claim for the same key the LLM will target.
      locked = widget.enliterator_claims.create!(
        key:        "summary",
        value:      "curated-truth",
        confidence: 1.0,
        status:     "draft",
        locked:     true
      )

      visit = described_class.new(widget, facet: "summary", llm: llm, embedder: embedder).call

      locked.reload
      # Untouched: same value, still live, never superseded.
      expect(locked.value).to eq("curated-truth")
      expect(locked.status).to eq("draft")
      expect(locked.superseded_by_id).to be_nil
      expect(locked.locked).to eq(true)

      # No replacement claim was created — only the curator's anchor remains.
      summary_claims = widget.enliterator_claims.where(key: "summary").to_a
      expect(summary_claims.length).to eq(1)
      expect(widget.enliterator_claims.live.where(key: "summary").count).to eq(1)

      # The UPDATE was recorded as a NOOP, not an update.
      expect(visit.reconciliation).to eq(
        "added" => [], "updated" => [], "deleted" => [], "noop" => [ "summary" ]
      )
    end
  end
end
