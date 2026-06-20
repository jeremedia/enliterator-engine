# frozen_string_literal: true

require "rails_helper"

# v0.46: the Lacuna integration in the staffing path. When config.record_lacunae
# is on, an unmet REQUIRED term opens a Lacuna and the empty-required parasite is
# evicted (not written / not left standing) instead of a contentless claim. Off,
# the path is byte-identical to v0.5. Mirrors the required_keys_spec harness.
RSpec.describe "Enliterator::Tending::Visitor lacunae (staffing path)" do
  # Gateway-shaped stub: returns canned claims + confidence, plus an optional
  # `absences` array in the parsed result (the v0.46.1 diagnosis producer, stubbed
  # here so the core visitor's diagnosis-capture path is exercisable without an adapter).
  class LacStub
    Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)
    attr_reader :tier, :calls

    def initialize(tier:, claims:, confidence: 0.95, absences: nil)
      @tier = tier; @claims = claims; @confidence = confidence; @absences = absences; @calls = 0
    end

    def model_id = "model-#{@tier}"

    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
      @calls += 1
      parsed = { "claims" => @claims, "confidence" => @confidence }
      parsed["absences"] = @absences if @absences
      Result.new(parsed: parsed, raw: { "tier" => @tier }, tokens: {})
    end
  end

  let(:widget)   { Widget.create!(title: "Thesis", body: "A thesis with a title page.") }
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Single effective tier (max_promotions 0): the cheap visit is the final visit,
  # so its claims drive finalize_final_visit! directly — no climb to reason about.
  def configure_policy!
    policy = Enliterator::Staffing::Policy.new do
      facet :authorship, tier: "cheap",
             terms: { authored_by: "The author(s).", advisor: "The advisor(s)." },
             required: [ :authored_by ]
      ladder [ "cheap", "quality" ]
      verify_floor "quality"
      max_promotions 0
    end
    Enliterator.configure { |c| c.staffing = policy }
  end

  def route!(cheap)
    allow(Enliterator).to receive(:llm).and_call_original
    allow(Enliterator).to receive(:llm).with(tier: "cheap").and_return(cheap)
    allow(Enliterator).to receive(:llm).with(tier: "quality").and_return(LacStub.new(tier: "quality", claims: []))
  end

  def tend! = Enliterator::Tending::Visitor.new(widget, facet: "authorship", embedder: embedder).call
  def live(key) = widget.enliterator_claims.live.find_by(key: key)
  def open_lacunae = Enliterator::Lacuna.open.where(tendable: widget)

  before { configure_policy! }

  # A live blank required claim, as a flag-OFF tend would have written it.
  def seed_blank!(key = "authored_by")
    v = widget.enliterator_visits.create!(facet: "authorship", status: "succeeded", applied: true, tier: "cheap")
    widget.enliterator_claims.create!(key: key, value: "", status: "draft", confidence: 0.1,
                                      attributed_to: "cheap:x", tier: "cheap", visit: v, context_id: nil)
  end

  def seed_good!(key = "authored_by", value = "Jane Doe", locked: false)
    v = widget.enliterator_visits.create!(facet: "authorship", status: "succeeded", applied: true, tier: "cheap")
    widget.enliterator_claims.create!(key: key, value: value, status: "draft", confidence: 0.9,
                                      attributed_to: "cheap:x", tier: "cheap", visit: v, context_id: nil, locked: locked)
  end

  describe "OFF (default) — byte-identical to v0.5" do
    it "writes the empty required claim and opens NO lacuna" do
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ]))
      v = tend!
      expect(live("authored_by")&.value).to eq("")          # empty claim written, as before
      expect(open_lacunae).to be_empty
      expect(v.reload.reconciliation["required_unmet"]).to be(true)
    end
  end

  describe "ON — a blank required term becomes a lacuna" do
    before { Enliterator.configure { |c| c.record_lacunae = true } }

    it "opens a lacuna and writes NO empty claim; still flags required_unmet" do
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ]))
      v = tend!
      expect(live("authored_by")).to be_nil                 # the parasite never reaches the store
      lac = open_lacunae.find_by(key: "authored_by")
      expect(lac).to be_present
      expect(lac.diagnosis).to eq("undiagnosed")            # no adapter absences in the core
      expect(v.reload.reconciliation["required_unmet"]).to be(true)
    end

    it "opens a lacuna for an OMITTED required term (no claim row at all)" do
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "advisor", "op" => "ADD", "value" => "Dr. A" } ]))
      tend!
      expect(open_lacunae.find_by(key: "authored_by")).to be_present
      expect(live("advisor")&.value).to eq("Dr. A")         # the non-required claim still writes
    end

    it "EVICTS a standing live blank (written flag-OFF) so it isn't shown beside the lacuna" do
      blank = seed_blank!
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ]))
      tend!
      expect(live("authored_by")).to be_nil                 # the standing blank is superseded
      expect(blank.reload.status).to eq("superseded")
      expect(open_lacunae.find_by(key: "authored_by")).to be_present
    end

    it "does NOT open a lacuna or retract when a prior GOOD claim satisfies the term" do
      good = seed_good!
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ]))
      v = tend!
      expect(live("authored_by")&.value).to eq("Jane Doe")  # good claim preserved, not retracted
      expect(good.reload.status).not_to eq("superseded")
      expect(open_lacunae.find_by(key: "authored_by")).to be_nil
      # asymmetry: the visit is still flagged unmet (visit-only final_unmet), with NO lacuna
      expect(v.reload.reconciliation["required_unmet"]).to be(true)
    end

    it "drops an op=DELETE on a required key so a prior good claim is NOT tombstoned" do
      good = seed_good!
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "DELETE" } ]))
      tend!
      expect(live("authored_by")&.value).to eq("Jane Doe")  # DELETE dropped, good claim survives
      expect(good.reload.status).not_to eq("superseded")
      expect(open_lacunae.find_by(key: "authored_by")).to be_nil
    end

    it "CLOSES an open lacuna when a later visit supplies the value" do
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ]))
      tend!
      expect(open_lacunae.find_by(key: "authored_by")).to be_present
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "Jane Doe" } ]))
      tend!
      expect(open_lacunae.find_by(key: "authored_by")).to be_nil
      closed = Enliterator::Lacuna.where(tendable: widget, key: "authored_by").first
      expect(closed.status).to eq("closed")
      expect(closed.closed_reason).to eq("supplied")
      expect(live("authored_by")&.value).to eq("Jane Doe")
    end

    it "refreshes (not duplicates) across two unmet beats" do
      stub = LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ])
      route!(stub); tend!
      route!(LacStub.new(tier: "cheap", claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ])); tend!
      expect(open_lacunae.where(key: "authored_by").count).to eq(1)
      expect(open_lacunae.find_by(key: "authored_by").detections).to eq(2)
    end

    it "captures a diagnosis from a stubbed parsed['absences'] (the v0.46.1 producer path)" do
      route!(LacStub.new(
        tier: "cheap",
        claims: [ { "key" => "authored_by", "op" => "ADD", "value" => "" } ],
        absences: [ { "term" => "authored_by", "diagnosis" => "defective_surrogate", "note" => "byline dropped" } ]
      ))
      tend!
      lac = open_lacunae.find_by(key: "authored_by")
      expect(lac.diagnosis).to eq("defective_surrogate")
      expect(lac.note).to eq("byline dropped")
    end
  end
end
