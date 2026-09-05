# frozen_string_literal: true

require "rails_helper"

# v0.76 — DERIVATION TAINT: unlicensed load, named at the point of use.
#
# The engine's derivation graph held only LINEAGE (same-key supersession —
# where the successor is the cure, not the victim) and the one real
# cross-claim flow (part-notes → synthesis) was purely textual. v0.76 mints
# the missing edge (role:"basis" derived_from refs at deep-read synthesis),
# stamps the implicit channel's substrate (input_refs.state_claim_ids), and
# reads taint at serve time: a basis ancestor ruled defective poisons its
# derivatives until they cite their way out (the independent-source cure).
# Taint marks, never deletes; derived at read, never stored.
RSpec.describe "v0.76 derivation taint" do
  class TaintStubLLM
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    def initialize(claims = [ { "key" => "argument", "op" => "ADD", "value" => "v", "confidence" => 0.8 } ])
      @claims = claims
    end
    def model_id = "stub"
    def tend(text:, facet:, state:, neighbors:)
      @last_state = state
      Result.new(parsed: { "claims" => @claims, "confidence" => 0.8 }, raw: {}, tokens: {})
    end
    attr_reader :last_state
  end

  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }
  let(:widget) do
    Widget.create!(title: "Continuity Thesis",
                   body: "## Introduction\nWhy continuity matters.\n## Method\nThree counties.")
  end

  def deep_read!(llm = TaintStubLLM.new)
    Enliterator::Tending::Reading.new(widget, llm: llm, embedder: embedder,
                                      synthesizes: [ "significance" ]).call
  end

  describe "76.1 — the basis edge" do
    it "synthesis claims carry role:basis refs to the part claims live at synthesis" do
      deep_read!                                     # first pass: parts get notes; no basis yet (parts had no claims)
      part_claim_ids = Enliterator::Claim.live.where(tendable_type: "Enliterator::Part").pluck(:id)
      expect(part_claim_ids.size).to eq(2)

      deep_read!                                     # second pass: parts fresh (skipped) but their claims now exist
      synth = widget.enliterator_claims.live.find_by(key: "argument")
      basis = Enliterator::Claim.basis_ids_of(synth)
      expect(basis).to match_array(part_claim_ids)   # multi-ancestor, the first in the store
      roles = synth.derived_from.map { |r| r["role"] }.uniq
      expect(roles).to include("basis")
    end

    it "an ORDINARY tend writes byte-identical derived_from — no basis, ever" do
      widget.tend!(facet: "summary", llm: TaintStubLLM.new([ { "key" => "summary", "op" => "ADD", "value" => "s", "confidence" => 0.8 } ]),
                   embedder: embedder)
      claim = widget.enliterator_claims.live.find_by(key: "summary")
      expect(claim.derived_from).to eq([])
    end

    it "adjudicate_absent! records EVERY superseded sibling as lineage; pure-lacuna writes []" do
      a = widget.enliterator_claims.create!(key: "advisor", value: "Ghost A", status: "draft")
      b = widget.enliterator_claims.create!(key: "advisor", value: "Ghost B", status: "draft")
      blank = widget.adjudicate_absent!(a, key: "advisor")
      ids = blank.derived_from.map { |r| r["id"] }
      expect(ids).to match_array([ a.id, b.id ])
      expect(blank.derived_from.map { |r| r["role"] }.compact).to be_empty   # lineage, role-less

      pure = widget.adjudicate_absent!(key: "orcid")
      expect(pure.derived_from).to eq([])
    end
  end

  describe "76.2 — the ids substrate" do
    it "stamps input_refs.state_claim_ids with exactly the claims the state carried" do
      existing = widget.enliterator_claims.create!(key: "prior", value: "p", status: "draft")
      visit = widget.tend!(facet: "summary", llm: TaintStubLLM.new, embedder: embedder)
      expect(visit.input_refs["state_claim_ids"]).to include(existing.id)
    end

    it "keeps the PROMPT state byte-identical — ids ride the visit, never the reader" do
      widget.enliterator_claims.create!(key: "prior", value: "p", status: "draft")
      stub = TaintStubLLM.new
      widget.tend!(facet: "summary", llm: stub, embedder: embedder)
      state_claim = stub.last_state[:claims].first
      expect(state_claim.keys).not_to include(:id, "id")
    end
  end

  describe "76.3 — the taint read" do
    def synthesis_with_poisonable_basis!
      deep_read!
      deep_read!
      basis_claim = Enliterator::Claim.live.where(tendable_type: "Enliterator::Part").first
      synth = widget.enliterator_claims.live.find_by(key: "argument")
      [ synth, basis_claim ]
    end

    it "a DEFECTIVE verdict on a basis ancestor taints the derived claim" do
      synth, basis = synthesis_with_poisonable_basis!
      expect(synth.tainted?).to be(false)
      Enliterator::Audit.create!(claim: basis, verdict: "contradicted", source: "examiner")
      expect(synth.tainted?).to be(true)
    end

    it "a HUMAN CORRECTION of a basis ancestor poisons (locked+human successor — no audit row needed)" do
      synth, basis = synthesis_with_poisonable_basis!
      basis.tendable.correct_claim!(basis, value: "the corrected note")
      expect(synth.tainted?).to be(true)
    end

    it "PLAIN model supersession of a basis ancestor is NOT poison — evolution, not refusal" do
      synth, basis = synthesis_with_poisonable_basis!
      repl = basis.tendable.enliterator_claims.create!(key: basis.key, value: "newer note",
                                                       status: "draft", visit: basis.visit)
      basis.supersede!(repl)
      expect(synth.tainted?).to be(false)
    end

    it "LINEAGE edges are never walked — a defective predecessor does not taint its own successor" do
      wrong = widget.enliterator_claims.create!(key: "advisor", value: "Wrong", status: "draft")
      Enliterator::Audit.create!(claim: wrong, verdict: "contradicted", source: "examiner")
      fix = widget.correct_claim!(wrong, value: "Right")   # derived_from → wrong, role-less
      expect(fix.tainted?).to be(false)                    # the successor is the cure
    end

    it "the CURE: an own supported verdict NEWER than the poisoning clears the taint" do
      synth, basis = synthesis_with_poisonable_basis!
      Enliterator::Audit.create!(claim: basis, verdict: "contradicted", source: "examiner",
                                 created_at: 2.days.ago, updated_at: 2.days.ago)
      expect(synth.tainted?).to be(true)
      Enliterator::Audit.create!(claim: synth, verdict: "supported", source: "examiner",
                                 created_at: 1.day.ago, updated_at: 1.day.ago)
      expect(synth.tainted?).to be(false)                  # cited its way out
      # ...but a cure OLDER than the poison does not count: re-poison later
      Enliterator::Audit.create!(claim: basis, verdict: "contradicted", source: "human")
      expect(synth.reload.tainted?).to be(true)
    end

    it "the attenuation cap: poison reaches TAINT_DEPTH hops and no further" do
      # Chain c5 → c4 → c3 → c2 → c1 (basis edges), poison at the root c1.
      # From c4 the poison is 3 hops up (inside the cap); from c5 it is 4
      # (attenuated away — long chains decay to the hard cap in v1).
      chain = [ widget.enliterator_claims.create!(key: "k1", value: "v", status: "draft") ]
      2.upto(5) do |i|
        chain << widget.enliterator_claims.create!(
          key: "k#{i}", value: "v", status: "draft",
          derived_from: [ { "type" => "claim", "id" => chain.last.id, "role" => "basis" } ]
        )
      end
      c1, c2, _c3, c4, c5 = chain
      Enliterator::Audit.create!(claim: c1, verdict: "contradicted", source: "examiner")

      expect(c2.tainted?).to be(true)    # 1 hop
      expect(c4.tainted?).to be(true)    # 3 hops — the cap, inclusive
      expect(c5.tainted?).to be(false)   # 4 hops — attenuated
    end

    it "a CYCLE terminates cleanly" do
      c1 = widget.enliterator_claims.create!(key: "k1", value: "v", status: "draft")
      c2 = widget.enliterator_claims.create!(key: "k2", value: "v", status: "draft",
                                             derived_from: [ { "type" => "claim", "id" => c1.id, "role" => "basis" } ])
      c1.update!(derived_from: [ { "type" => "claim", "id" => c2.id, "role" => "basis" } ])
      expect(c2.tainted?).to be(false)   # no poison anywhere; the guard just has to terminate
    end

    it "batch ≡ instance parity" do
      synth, basis = synthesis_with_poisonable_basis!
      Enliterator::Audit.create!(claim: basis, verdict: "unsupported", source: "examiner")
      clean = widget.enliterator_claims.live.find_by(key: "significance") ||
              widget.enliterator_claims.create!(key: "unrelated", value: "v", status: "draft")
      batch = Enliterator::Claim.taint_for([ synth, clean ])
      expect(batch[synth.id]).to eq(synth.tainted?)
      expect(batch[clean.id]).to eq(clean.tainted?)
    end
  end

  describe "76.4 — serve points" do
    around do |ex|
      prior = Enliterator.configuration.audit_warrant
      ex.run
      Enliterator.configuration.audit_warrant = prior
    end

    it "claim_card: tainted absent when flag off, absent when false, true when true" do
      c = widget.enliterator_claims.create!(key: "k", value: "v", status: "draft")
      tool = Enliterator::Mcp::Tool.new

      Enliterator.configuration.audit_warrant = nil
      expect(tool.send(:claim_card, c)).not_to have_key(:tainted)

      Enliterator.configuration.audit_warrant = true
      expect(tool.send(:claim_card, c)).not_to have_key(:tainted)          # false ⇒ absent
      expect(tool.send(:claim_card, c, tainted: true)[:tainted]).to be(true)
    end

    it "the chat widget renders license chips only when the card data carries them" do
      bare = Enliterator::Chat::Widget.send(:claim_row, { key: "k", value: "v" })
      expect(bare).not_to include("tainted", "stale")

      full = Enliterator::Chat::Widget.send(:claim_row,
        { key: "k", value: "v", warrant: "asserted", warrant_stale: true, tainted: true })
      expect(full).to include("asserted", "stale", "tainted")
    end
  end
end
