# frozen_string_literal: true

require "rails_helper"

# v0.70 — the model bake-off.
#
# The question that prompted it: a tier's backend changed under a live collection
# and the tending log's average confidence went UP. That is not evidence — it is
# self-report. These specs pin the two properties that make the bake-off evidence
# instead: it writes nothing, and the examiner is blind to which tier produced the
# claim it is judging.
RSpec.describe Enliterator::Bakeoff do
  let(:widget)  { Widget.create!(title: "T", body: "the body text") }
  let(:widget2) { Widget.create!(title: "U", body: "another body") }

  # Produces a fixed number of claims, tagged with its own tier so a spec can tell
  # whose claims reached the examiner.
  class ArmStub
    Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
    attr_reader :tier
    def initialize(tier, n_claims:, model: nil)
      @tier = tier; @n = n_claims; @model = model
    end
    def model_id = @tier
    def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil)
      claims = Array.new(@n) { |i| { "key" => "summary", "value" => "#{@tier} claim #{i}" } }
      Result.new(parsed: { "claims" => claims, "confidence" => 0.9 },
                 raw: {}, tokens: { "total" => 100 }, model: @model)
    end
  end

  # Records every (key, value, source) it is asked to judge.
  class RecordingExaminer
    attr_reader :seen
    def initialize(verdicts: nil)
      @seen = []
      @verdicts = verdicts   # optional queue of verdicts to return, cycled
      @i = -1
    end
    def verdict_for(facet:, key:, value:, source:, context: nil)
      @seen << { facet: facet, key: key, value: value, source: source, context: context }
      @i += 1
      v = @verdicts ? @verdicts[@i % @verdicts.size] : "supported"
      { verdict: v, rationale: "r", confidence: 0.9, corrected_value: {}, tier: "x", model: "y" }
    end
  end

  def arms(a, b) = { "tier-a" => a, "tier-b" => b }

  def stub_tiers!(map)
    allow(Enliterator).to receive(:llm).and_call_original
    map.each { |tier, adapter| allow(Enliterator).to receive(:llm).with(tier: tier).and_return(adapter) }
  end

  describe "it writes NOTHING" do
    it "creates no Visit, Claim, or Audit rows" do
      stub_tiers!(arms(ArmStub.new("tier-a", n_claims: 2), ArmStub.new("tier-b", n_claims: 2)))

      before = [ Enliterator::Visit.count, Enliterator::Claim.count, Enliterator::Audit.count ]

      described_class.run([ widget, widget2 ], facet: "summary",
                          tiers: %w[tier-a tier-b], examiner: RecordingExaminer.new)

      after = [ Enliterator::Visit.count, Enliterator::Claim.count, Enliterator::Audit.count ]
      expect(after).to eq(before)
    end
  end

  describe "the examiner is blind" do
    it "is never told the tier, the model, or the confidence" do
      examiner = RecordingExaminer.new
      stub_tiers!(arms(ArmStub.new("tier-a", n_claims: 1), ArmStub.new("tier-b", n_claims: 1)))

      described_class.run([ widget ], facet: "summary", tiers: %w[tier-a tier-b], examiner: examiner)

      expect(examiner.seen.size).to eq(2)
      expect(examiner.seen.first.keys).to contain_exactly(:facet, :key, :value, :source, :context)
    end

    it "judges both arms with the SAME instrument" do
      examiner = RecordingExaminer.new
      stub_tiers!(arms(ArmStub.new("tier-a", n_claims: 1), ArmStub.new("tier-b", n_claims: 1)))
      described_class.run([ widget ], facet: "summary", tiers: %w[tier-a tier-b], examiner: examiner)
      # One examiner object saw claims from both tiers — not one instrument per arm.
      expect(examiner.seen.map { |s| s[:value] }).to include(a_string_matching(/tier-a/), a_string_matching(/tier-b/))
    end
  end

  describe "the numbers" do
    it "computes supported_rate exactly as Audit.accuracy does (unverifiable excluded)" do
      # 4 claims per arm; verdict cycle: supported, unsupported, unverifiable, supported
      examiner = RecordingExaminer.new(verdicts: %w[supported unsupported unverifiable supported])
      stub_tiers!(arms(ArmStub.new("tier-a", n_claims: 4), ArmStub.new("tier-b", n_claims: 4)))

      a, = described_class.run([ widget ], facet: "summary", tiers: %w[tier-a], examiner: examiner)

      expect(a.claims).to eq(4)
      expect(a.counts["supported"]).to eq(2)
      expect(a.counts["unverifiable"]).to eq(1)
      # 2 supported / 3 DECIDED (unverifiable excluded from the denominator)
      expect(a.supported_rate).to eq(0.667)
    end

    it "reports per-arm volume and cost alongside the rate" do
      stub_tiers!(arms(ArmStub.new("tier-a", n_claims: 3), ArmStub.new("tier-b", n_claims: 1)))
      a, b = described_class.run([ widget, widget2 ], facet: "summary",
                                 tiers: %w[tier-a tier-b], examiner: RecordingExaminer.new)

      expect(a.claims).to eq(6)                 # 3 claims x 2 records
      expect(a.claims_per_record).to eq(3.0)
      expect(a.tokens).to eq(200)               # 100 per record
      expect(b.claims).to eq(2)
      expect(b.tokens_per_claim).to eq(100)
    end

    it "records the RESOLVED model per arm when the adapter reports one (v0.68)" do
      stub_tiers!(arms(ArmStub.new("tier-a", n_claims: 1, model: "bedrock_mantle/openai.gpt-5.4"),
                       ArmStub.new("tier-b", n_claims: 1)))
      a, b = described_class.run([ widget ], facet: "summary",
                                 tiers: %w[tier-a tier-b], examiner: RecordingExaminer.new)
      expect(a.model).to eq("bedrock_mantle/openai.gpt-5.4")
      expect(b.model).to eq("tier-b")   # falls back to the alias
    end
  end

  # The counterweight to supported_rate. Precision alone rewards a reader for
  # saying less; on a facet with required terms the engine knows what SHOULD have
  # been produced, and that is the only recall signal available.
  describe "coverage (recall)" do
    # Emits exactly the claims it is given, so a spec can model a reader that
    # omits — or blanks — a required term.
    class ScriptedArm
      Result = Struct.new(:parsed, :raw, :tokens, :model, keyword_init: true)
      def initialize(tier, claims) = (@tier = tier; @claims = claims)
      def model_id = @tier
      def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil)
        @seen_required = required
        Result.new(parsed: { "claims" => @claims, "confidence" => 0.9 }, raw: {}, tokens: { "total" => 10 })
      end
      attr_reader :seen_required
    end

    def run_with(claims, required: [ "authored_by" ])
      arm = ScriptedArm.new("tier-a", claims)
      stub_tiers!("tier-a" => arm)
      out, = described_class.run([ widget ], facet: "authorship", tiers: %w[tier-a],
                                 required: required, examiner: RecordingExaminer.new)
      [ out, arm ]
    end

    it "is nil when the facet declares no required terms — an honest absence, not a zero" do
      out, = run_with([ { "key" => "note", "value" => "x" } ], required: [])
      expect(out.coverage).to be_nil
    end

    it "counts a required term filled with a real value" do
      out, = run_with([ { "key" => "authored_by", "value" => "A. Author" } ])
      expect(out.coverage).to eq(1.0)
    end

    it "does NOT count a required term the reader omitted entirely" do
      out, = run_with([ { "key" => "summary", "value" => "something else" } ])
      expect(out.coverage).to eq(0.0)
    end

    it "does NOT count a BLANK value as met — an empty claim is not an answer" do
      out, = run_with([ { "key" => "authored_by", "value" => "" } ])
      expect(out.coverage).to eq(0.0)
    end

    it "exposes the quiet reader: perfect precision, zero coverage" do
      out, = run_with([ { "key" => "summary", "value" => "a safe true thing" } ])
      expect(out.supported_rate).to eq(1.0)   # everything it said was supported
      expect(out.coverage).to eq(0.0)         # and it never did the job
    end

    it "hands the required terms to the reader — coverage must not score an unstated obligation" do
      _, arm = run_with([ { "key" => "authored_by", "value" => "A" } ])
      expect(arm.seen_required).to eq([ "authored_by" ])
    end
  end

  describe "resilience" do
    class ExplodingStub < ArmStub
      def tend(**) = raise(Errno::ECONNREFUSED)
    end

    it "records a failed record and keeps measuring the rest of the arm" do
      stub_tiers!("tier-a" => ExplodingStub.new("tier-a", n_claims: 1))
      a, = described_class.run([ widget, widget2 ], facet: "summary",
                               tiers: %w[tier-a], examiner: RecordingExaminer.new)
      expect(a.errors.size).to eq(2)
      expect(a.claims).to eq(0)
      expect(a.supported_rate).to be_nil    # nothing decided — not a zero
    end

    it "skips records with no source text rather than scoring them" do
      blank = Widget.create!(title: "", body: "")
      allow(blank).to receive(:enliterator_text).and_return("")
      stub_tiers!("tier-a" => ArmStub.new("tier-a", n_claims: 1))
      a, = described_class.run([ blank ], facet: "summary", tiers: %w[tier-a],
                               examiner: RecordingExaminer.new)
      expect(a.claims).to eq(0)
    end
  end
end
