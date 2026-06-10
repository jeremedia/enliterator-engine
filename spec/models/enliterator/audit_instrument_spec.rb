# frozen_string_literal: true

require "rails_helper"

# v0.18 phase 2 — the instrument: stratified sampling, the examiner's
# grounding + blindness, the process-rate accuracy, and the human anchor.
RSpec.describe "Enliterator::Audit instrument (v0.18)" do
  def visit!(record, facet: "summary", tier: "cheap")
    record.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true, tier: tier)
  end

  def claim!(record, key: "summary", value: "a take", facet: "summary", tier: "cheap", visit: nil)
    record.enliterator_claims.create!(key: key, value: value, status: "draft",
                                      tier: tier, visit: visit || visit!(record, facet: facet, tier: tier))
  end

  def audit!(claim, verdict:, source: "examiner", at: Time.current, corrected: nil)
    Enliterator::Audit.create!(claim: claim, verdict: verdict, source: source,
                               corrected_claim: corrected, created_at: at, updated_at: at)
  end

  describe ".sample" do
    it "stratifies across facet × tier cells and excludes audited/locked/host-asserted/dead claims" do
      w = Widget.create!(title: "w", body: "b")
      3.times { |i| claim!(w, key: "k#{i}", facet: "summary", tier: "cheap") }
      3.times { |i| claim!(w, key: "a#{i}", facet: "authorship", tier: "quality") }
      audited = claim!(w, key: "audited", facet: "summary", tier: "cheap")
      audit!(audited, verdict: "supported")
      w.assert_claim!(key: "host_fact", value: 2020)                       # visit_id NULL — out
      locked = claim!(w, key: "locked_one", facet: "summary", tier: "cheap")
      locked.update!(locked: true)                                          # curator anchor — out
      dead = claim!(w, key: "dead", facet: "summary", tier: "cheap")
      dead.update!(status: "superseded")                                    # not live — out

      result = Enliterator::Audit.sample(4)
      expect(result[:allocation]).to eq({ "authorship/quality" => 2, "summary/cheap" => 2 })
      keys = result[:claims].map(&:key)
      expect(keys).not_to include("audited", "host_fact", "locked_one", "dead")
      expect(result[:claims].size).to eq(4)
    end

    it "buckets tier NULL as 'unknown' instead of dropping v0.1-era claims" do
      w = Widget.create!(title: "w", body: "b")
      v = visit!(w)
      w.enliterator_claims.create!(key: "old", value: "x", status: "draft", visit: v, tier: nil)
      result = Enliterator::Audit.sample(1)
      expect(result[:allocation]).to eq({ "summary/unknown" => 1 })
    end
  end

  describe Enliterator::Audit::Examiner do
    class ExaminerStub
      Result = Struct.new(:h) do
        def [](k) = h[k.to_s]
      end
      attr_reader :last_messages
      def initialize(verdict: "supported", corrected: nil)
        @verdict = verdict
        @corrected = corrected
      end
      def model_id = "stub-quality"
      def decide(messages:, schema:, tool_name:, tags: [])
        @last_messages = messages
        { "verdict" => @verdict, "rationale" => "the source says so", "confidence" => 0.9,
          "corrected_value" => @corrected }.compact
      end
    end

    it "grounds in the FULL source (digest + chars stamped) and stays blind to tier/confidence" do
      w = Widget.create!(title: "w", body: "B" * 500)
      c = claim!(w, value: "a confident take")
      c.update!(confidence: 1.0)
      stub = ExaminerStub.new

      audit = described_class.new(llm: stub).examine!(c)
      expect(audit).to be_a(Enliterator::Audit)
      expect(audit.verdict).to eq("supported")
      expect(audit.source_chars).to eq(w.enliterator_text(facet: "summary").length)
      expect(audit.source_digest).to eq(Digest::MD5.hexdigest(w.enliterator_text(facet: "summary")))
      expect(audit.source_truncated).to be(false)
      expect(audit.auditor).to include("stub-quality")

      prompt = stub.last_messages.last[:content]
      expect(prompt).to include("B" * 500)            # the full text, not a snippet
      expect(prompt).not_to include("1.0")            # blind to the original confidence
      expect(prompt).not_to include("cheap")          # blind to the tier
      expect(stub.last_messages.first[:content]).to include("NEVER grounds")  # verbatim definitions
    end

    it "stamps truncation when the ceiling bites — and the digest still covers the FULL source" do
      Enliterator.configuration.audit_source_chars = 100
      w = Widget.create!(title: "w", body: "X" * 5_000)
      audit = described_class.new(llm: ExaminerStub.new).examine!(claim!(w))
      expect(audit.source_truncated).to be(true)
      expect(audit.source_chars).to be > 100
      expect(audit.source_digest).to eq(Digest::MD5.hexdigest(w.enliterator_text(facet: "summary")))
    end

    it "feeds the term's controlled meaning from the claim's own context" do
      Enliterator.configure do |c|
        c.staffing = Enliterator::Staffing::Policy.new do
          facet :summary, tier: "cheap", terms: { summary: "A faithful abstract of the document." }
          ladder [ "cheap" ]
        end
      end
      w = Widget.create!(title: "w", body: "b")
      stub = ExaminerStub.new
      described_class.new(llm: stub).examine!(claim!(w))
      expect(stub.last_messages.last[:content]).to include("A faithful abstract")
    end

    it "returns :blank_source (nothing to verify) and :unavailable (Null) as named skips" do
      blank = Widget.create!(title: nil, body: nil)
      c = claim!(blank)
      expect(described_class.new(llm: ExaminerStub.new).examine!(c)).to eq(:blank_source)

      w = Widget.create!(title: "w", body: "b")
      expect(described_class.new.examine!(claim!(w))).to eq(:unavailable)   # resolves Null
    end
  end

  describe ".accuracy (the process rate)" do
    it "keeps superseded claims' audits in the headline — re-tending cannot launder the number" do
      w = Widget.create!(title: "w", body: "b")
      bad = claim!(w, key: "summary")
      audit!(bad, verdict: "contradicted")
      replacement = w.enliterator_claims.create!(key: "summary", value: "newer", status: "draft",
                                                 tier: "cheap", visit: bad.visit)
      bad.supersede!(replacement)   # the audited claim is dead; its audit is not

      cell = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(cell[:audited]).to eq(1)
      expect(cell[:contradicted]).to eq(1)
      expect(cell[:live]).to eq(0)                       # the stock view shows the drain
      expect(cell[:supported_rate]).to eq(0.0)
    end

    it "the human verdict outranks the examiner's; unverifiable stays out of the denominator" do
      w = Widget.create!(title: "w", body: "b")
      c1 = claim!(w, key: "k1")
      audit!(c1, verdict: "supported", at: 2.days.ago)
      audit!(c1, verdict: "contradicted", source: "human", at: 1.day.ago)
      c2 = claim!(w, key: "k2")
      audit!(c2, verdict: "unverifiable")

      cell = Enliterator::Audit.accuracy.find { |c| c[:facet] == "summary" }
      expect(cell[:contradicted]).to eq(1)               # the human's verdict, not the examiner's
      expect(cell[:supported]).to eq(0)
      expect(cell[:unverifiable]).to eq(1)
      expect(cell[:supported_rate]).to eq(0.0)           # denominator = decided only (1)
    end
  end

  describe ".anchor_agreement" do
    it "binary agreement, min-n gate, and the overruled-supported line" do
      w = Widget.create!(title: "w", body: "b")
      # 3 overlaps: agree-supported, agree-defective (cross-verdict), overruled-supported.
      a = claim!(w, key: "a"); audit!(a, verdict: "supported");    audit!(a, verdict: "supported", source: "human")
      b = claim!(w, key: "b"); audit!(b, verdict: "unsupported");  audit!(b, verdict: "contradicted", source: "human")
      c = claim!(w, key: "c"); audit!(c, verdict: "supported");    audit!(c, verdict: "contradicted", source: "human")
      d = claim!(w, key: "d"); audit!(d, verdict: "unverifiable"); audit!(d, verdict: "supported", source: "human")

      ag = Enliterator::Audit.anchor_agreement
      expect(ag[:overlaps]).to eq(3)                     # the unverifiable pair is excluded
      expect(ag[:agreements]).to eq(2)                   # cross-verdict defective pair AGREES (binary)
      expect(ag[:rate]).to be_nil                        # below MIN_AGREEMENT_OVERLAPS
      expect(ag[:examiner_supported]).to eq(2)
      expect(ag[:overruled_supported]).to eq(1)          # the false-supported, caught
    end
  end
end
