# frozen_string_literal: true

require "rails_helper"

# v0.73 — ADJUDICATED ABSENCE.
#
# The v0.72 campaign probed three facts (PROBE A/B/C), recorded here as
# permanent specs:
#   A. a tombstone (retract_claim!) does NOT suppress re-assertion — the
#      phantom returns (live_claim_for nil → normalize_op → ADD).
#   B. a live LOCKED BLANK claim blocks re-assertion permanently — the durable
#      primitive existed; only its creation surface was missing.
#   C. pre-v0.73, a locked blank cost three uncoordinated penalties: full
#      escalation on every re-tend, a perpetually open lacuna, unmintable
#      `verified`.
# v0.73 gives the primitive its meaning (effective_required lifts the
# obligation), closes the reconciler's ADD durability hole, and adds the verb.
RSpec.describe "v0.73 adjudicated absence" do
  class AbsenceReaderStub
    Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
    attr_reader :calls
    def initialize(claims: [])
      @claims = claims
      @calls  = []
    end
    def model_id = "stub"
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      @calls << { required: required }
      Result.new(parsed: { "claims" => @claims, "confidence" => 0.9 }, raw: {}, tokens: {})
    end
  end

  let(:widget) { Widget.create!(title: "T", body: "body text") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  def staff!(cheap:, quality: nil)
    Enliterator.configure do |c|
      c.record_lacunae = true
      c.staffing = Enliterator::Staffing::Policy.new do
        facet :authorship, tier: "cheap", required: [ :authored_by ],
              terms: { authored_by: "Who wrote it.", contributor: "Who helped." }
        ladder [ "cheap", "quality" ]
        verify_floor "cheap"
      end
    end
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(quality || cheap)
  end

  def tend! = Enliterator::Tending::Visitor.new(widget, facet: "authorship", embedder: embedder).call

  around do |ex|
    prior = Enliterator.configuration.record_lacunae
    ex.run
    Enliterator.configuration.record_lacunae = prior
  end

  describe "the three penalty sites (PROBE C, closed)" do
    it "BASELINE (the byte-identity predicate): with no locked blank, an unmet required term still escalates, opens a lacuna, flags the visit" do
      cheap = AbsenceReaderStub.new
      staff!(cheap: cheap)
      tend!
      expect(widget.enliterator_visits.count).to eq(2)                     # climbed the ladder
      expect(widget.enliterator_visits.order(:id).last.tier).to eq("quality")
      expect(widget.enliterator_lacunae.open.where(key: "authored_by")).to exist
      expect(cheap.calls.first[:required]).to include("authored_by")       # the obligation shipped
    end

    it "an adjudicated key escalates nothing, opens nothing, and the reader is never told to force it" do
      widget.adjudicate_absent!(key: "authored_by")
      cheap = AbsenceReaderStub.new
      staff!(cheap: cheap)
      tend!
      visits = widget.enliterator_visits.order(:id)
      expect(visits.count).to eq(1)                                        # no climb
      expect(visits.last.tier).to eq("cheap")
      expect(visits.last.reconciliation["required_unmet"]).to be_falsey    # `verified` gate follows
      expect(widget.enliterator_lacunae.open.where(key: "authored_by")).not_to exist
      expect(cheap.calls.first[:required]).to be_nil                       # kwarg omitted (nil, not [])
    end

    it "lifts ONLY the adjudicated key — the narrowest predicate, never general live-awareness" do
      Enliterator.configure do |c|
        c.record_lacunae = true
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :authorship, tier: "cheap", required: [ :authored_by, :contributor ],
                terms: { authored_by: "Who wrote it.", contributor: "Who helped." }
          ladder [ "cheap" ]
          verify_floor "cheap"
        end
      end
      cheap = AbsenceReaderStub.new
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)

      widget.adjudicate_absent!(key: "authored_by")
      tend!
      expect(cheap.calls.first[:required].map(&:to_s)).to eq([ "contributor" ])
      expect(widget.enliterator_lacunae.open.where(key: "contributor")).to exist
      expect(widget.enliterator_lacunae.open.where(key: "authored_by")).not_to exist
    end

    it "an UNLOCKED blank or a locked NON-blank lifts nothing (the filter tests exactly locked && blank)" do
      widget.enliterator_claims.create!(key: "authored_by", value: "", status: "draft", locked: false)
      cheap = AbsenceReaderStub.new
      staff!(cheap: cheap)
      tend!
      expect(cheap.calls.first[:required]).to include("authored_by")

      widget.enliterator_claims.live.where(key: "authored_by").destroy_all
      widget.assert_claim!(key: "authored_by", value: "A Real Author")   # locked NON-blank
      cheap2 = AbsenceReaderStub.new
      staff!(cheap: cheap2)
      tend!
      expect(cheap2.calls.first[:required]).to include("authored_by")
    end
  end

  describe "durability (PROBE A/B + the ADD hole)" do
    def reconcile_with!(claims)
      stub = AbsenceReaderStub.new(claims: claims)
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          assign :authorship, tier: "cheap"
          ladder [ "cheap" ]
          verify_floor "cheap"
        end
      end
      allow(Enliterator).to receive(:llm).and_call_original
      allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(stub)
      tend!
    end

    it "PROBE A, permanent: a retract_claim! tombstone does NOT stop re-assertion — the phantom returns" do
      widget.enliterator_claims.create!(key: "authored_by", value: "Phantom", status: "draft")
      widget.retract_claim!(key: "authored_by")
      reconcile_with!([ { "key" => "authored_by", "value" => "Phantom", "op" => "ADD" } ])
      expect(widget.enliterator_claims.live.where(key: "authored_by").count).to eq(1)  # it came back
    end

    it "PROBE B + the ADD hole: an explicit op:ADD against the locked blank NOOPs — no live sibling, ever" do
      blank = widget.adjudicate_absent!(key: "authored_by")
      reconcile_with!([ { "key" => "authored_by", "value" => "Phantom", "op" => "ADD" } ])

      live = widget.enliterator_claims.live.where(key: "authored_by")
      expect(live.count).to eq(1)
      expect(live.first).to eq(blank)
      expect(widget.enliterator_visits.order(:id).last.reconciliation["noop"]).to include("authored_by")
    end

    it "the ADD guard protects correct_claim! anchors too (a latent pre-v0.73 hole)" do
      wrong = widget.enliterator_claims.create!(key: "authored_by", value: "Wrong", status: "draft")
      anchor = widget.correct_claim!(wrong, value: "Right Author")
      reconcile_with!([ { "key" => "authored_by", "value" => "Wrong Again", "op" => "ADD" } ])

      live = widget.enliterator_claims.live.where(key: "authored_by")
      expect(live.count).to eq(1)
      expect(live.first).to eq(anchor)
    end
  end

  describe "Tendable#adjudicate_absent! (the verb)" do
    it "mints a locked blank verified human claim, supersedes the phantom, derives from it" do
      phantom = widget.enliterator_claims.create!(key: "advisor", value: "Nobody Real", status: "draft")
      fresh = widget.adjudicate_absent!(phantom, key: "advisor", note: "no advisor exists for this record")

      expect(fresh.value).to eq("")
      expect(fresh.locked).to be(true)
      expect(fresh.status).to eq("verified")
      expect(fresh.visit).to be_nil
      expect(fresh.attributed_to).to eq("human:no advisor exists for this record")
      expect(fresh.derived_from).to eq([ { "type" => "claim", "id" => phantom.id } ])
      phantom.reload
      expect(phantom.superseded_by_id).to eq(fresh.id)
    end

    it "authority is the KEY-SCOPE: duplicate live siblings are ALL superseded (no nondeterministic survivor)" do
      a = widget.enliterator_claims.create!(key: "advisor", value: "Ghost A", status: "draft")
      b = widget.enliterator_claims.create!(key: "advisor", value: "Ghost B", status: "draft")

      fresh = widget.adjudicate_absent!(a, key: "advisor")
      expect(a.reload.superseded_by_id).to eq(fresh.id)
      expect(b.reload.superseded_by_id).to eq(fresh.id)
      expect(widget.enliterator_claims.live.where(key: "advisor").to_a).to eq([ fresh ])
    end

    it "COLLECTS before minting — the fresh blank never supersedes itself" do
      widget.enliterator_claims.create!(key: "advisor", value: "Ghost", status: "draft")
      fresh = widget.adjudicate_absent!(key: "advisor")
      expect(fresh.reload.superseded_by_id).to be_nil
      expect(fresh.status).to eq("verified")
    end

    it "raises AdjudicationConflict over a locked NON-blank — another curator ruled a VALUE" do
      widget.assert_claim!(key: "advisor", value: "Dr. Real")
      expect {
        widget.adjudicate_absent!(key: "advisor")
      }.to raise_error(Enliterator::Claim::AdjudicationConflict, /Dr\. Real/)
    end

    it "double adjudication is a NO-OP: the standing blank is returned, no provenance noise" do
      first = widget.adjudicate_absent!(key: "advisor")
      expect {
        expect(widget.adjudicate_absent!(key: "advisor")).to eq(first)
      }.not_to change(Enliterator::Claim, :count)
      expect(first.reload.superseded_by_id).to be_nil
    end

    it "a standing blank anchors: a phantom minted BESIDE a prior adjudication is superseded to it" do
      blank = widget.adjudicate_absent!(key: "advisor")
      phantom = widget.enliterator_claims.create!(key: "advisor", value: "Ghost", status: "draft")
      expect(widget.adjudicate_absent!(key: "advisor")).to eq(blank)
      expect(phantom.reload.superseded_by_id).to eq(blank.id)
    end

    it "raises AlreadySuperseded when the passed claim is stale AND no live work remains" do
      stale = widget.enliterator_claims.create!(key: "advisor", value: "Ghost", status: "draft")
      stale.update!(status: "superseded")
      expect {
        widget.adjudicate_absent!(stale, key: "advisor")
      }.to raise_error(Enliterator::Claim::AlreadySuperseded)
    end

    it "closes open lacunae with reason `adjudicated` — after adjudication the gap is not a known-unknown" do
      lac = Enliterator::Lacuna.open_or_refresh(
        tendable: widget, facet: "authorship", key: "advisor",
        diagnosis: "silent", note: "no advisor found"
      )
      widget.adjudicate_absent!(key: "advisor")
      lac.reload
      expect(lac.status).to eq("closed")
      expect(lac.closed_reason).to eq("adjudicated")
    end
  end
end
