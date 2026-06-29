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

  # ── reconcile! op/existence boundary ─────────────────────────────────────────
  # Six cases pinning the reconcile! contract at the NOOP/UPDATE × existence ×
  # value-presence boundary. Cases 1 and 5b are the bug-fix cases (RED before
  # the fix); cases 2–4, 5a, and 6 are regressions that must stay green.
  describe "#reconcile! — NOOP/UPDATE on a nonexistent key" do
    # A thin injected-llm stub — reconcile! never calls #tend, so only model_id
    # matters (for Visitor initializer). We call reconcile! directly.
    let(:llm) do
      Class.new do
        def model_id = "stub-reconcile"
      end.new
    end

    subject(:visitor) do
      described_class.new(widget, facet: "summary", llm: llm, embedder: embedder)
    end

    # Build a one-element proposed array with the given op and value.
    def propose(op:, value: "synthesized-value")
      [ { "key" => "summary", "op" => op, "value" => value, "confidence" => 0.8 } ]
    end

    # Create a minimal running Visit row so reconcile! can stamp created claims.
    let(:run_visit) do
      widget.enliterator_visits.create!(
        facet: "summary", status: "running", model: "stub-reconcile",
        tier: "cheap", applied: true, prompt_version: "v0.1",
        started_at: Time.current
      )
    end

    def reconcile!(proposed)
      visitor.reconcile!(proposed, run_visit, attributed_to: "stub", tier: "cheap", may_verify: false)
    end

    # ── Case 1 (RED before fix): NOOP with value, no live claim → must ADD ────
    it "NOOP with a non-blank value on a nonexistent key is treated as ADD" do
      recon = reconcile!(propose(op: "NOOP", value: "synthesized-coverage"))

      expect(recon[:added]).to include("summary"), "expected :added to include 'summary'"
      expect(recon[:noop]).not_to include("summary")

      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim).to be_present
      expect(claim.value).to eq("synthesized-coverage")
    end

    # ── Case 2 (regression GREEN): UPDATE with value, no live claim → ADD ─────
    it "UPDATE with a non-blank value on a nonexistent key is treated as ADD" do
      recon = reconcile!(propose(op: "UPDATE", value: "introduced-concepts"))

      expect(recon[:added]).to include("summary")
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim).to be_present
      expect(claim.value).to eq("introduced-concepts")
    end

    # ── Case 3 (regression): NOOP against existing live claim → noop only ─────
    it "NOOP against an existing live claim is still a noop (no duplicate written)" do
      widget.enliterator_claims.create!(key: "summary", value: "established", confidence: 0.9, status: "draft")

      recon = reconcile!(propose(op: "NOOP", value: "whatever"))

      expect(recon[:noop]).to include("summary")
      expect(recon[:added]).not_to include("summary")
      # Exactly one live claim; value unchanged.
      expect(widget.enliterator_claims.live.where(key: "summary").count).to eq(1)
      expect(widget.enliterator_claims.live.find_by(key: "summary").value).to eq("established")
    end

    # ── Case 4 (regression): UPDATE against existing → supersedes it ──────────
    it "UPDATE against an existing live claim supersedes it and writes the new value" do
      existing = widget.enliterator_claims.create!(
        key: "summary", value: "old-value", confidence: 0.7, status: "draft"
      )

      recon = reconcile!(propose(op: "UPDATE", value: "updated-value"))

      expect(recon[:updated]).to include("summary")
      existing.reload
      expect(existing.status).to eq("superseded")
      live = widget.enliterator_claims.live.find_by(key: "summary")
      expect(live).to be_present
      expect(live.value).to eq("updated-value")
    end

    # ── Case 5a (regression): NOOP + blank value, nonexistent → noop (not written)
    it "NOOP with a blank value on a nonexistent key is NOT written" do
      recon = reconcile!(propose(op: "NOOP", value: ""))

      expect(recon[:noop]).to include("summary")
      expect(recon[:added]).not_to include("summary")
      expect(widget.enliterator_claims.live.where(key: "summary")).to be_empty
    end

    # ── Case 5b (RED before fix): UPDATE + blank value, nonexistent → noop ────
    it "UPDATE with a blank value on a nonexistent key is NOT written" do
      recon = reconcile!(propose(op: "UPDATE", value: ""))

      expect(recon[:noop]).to include("summary"), "expected :noop to include 'summary' — blank UPDATE on nonexistent must not write"
      expect(recon[:added]).not_to include("summary")
      expect(widget.enliterator_claims.live.where(key: "summary")).to be_empty
    end

    # ── Case 6 (regression): DELETE on nonexistent → noop ────────────────────
    it "DELETE on a nonexistent key is a noop" do
      recon = reconcile!(propose(op: "DELETE", value: nil))

      expect(recon[:noop]).to include("summary")
      expect(widget.enliterator_claims.live.where(key: "summary")).to be_empty
    end
  end
end
