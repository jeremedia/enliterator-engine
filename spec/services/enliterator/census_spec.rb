# frozen_string_literal: true

require "rails_helper"

# v0.72 — the census: full-population grounded verdict sweep.
#
# The standing sampler equalizes count per cell (no per-key power); the census
# walks every live engine-derived claim on a facet. Writes NOTHING by default;
# FLAG files only defective verdicts as agent audits — the v0.26 primitive that
# is deliberately OUTSIDE the accuracy instrument.
RSpec.describe Enliterator::Census do
  # Scripted examiner: verdict decided by the claim VALUE so fixtures read as
  # "this value is supported, that one contradicted" at the call site.
  class CensusExaminerStub
    attr_reader :calls
    def initialize(map = {}, default = "supported")
      @map = map
      @default = default
      @calls = []
    end

    def verdict_for(facet:, key:, value:, source:, context: nil, truncated: nil)
      @calls << { facet: facet, key: key, value: value, source: source, context: context, truncated: truncated }
      v = @map.fetch(value.to_s, @default)
      return v if v.is_a?(Symbol)
      raise v if v.is_a?(Class) && v <= StandardError
      { verdict: v, rationale: "because the source says so", corrected_value: {},
        confidence: 0.9, tier: "stub", model: "stub-model" }
    end
  end

  def visit!(record, facet: "summary")
    record.enliterator_visits.create!(facet: facet, status: "succeeded", applied: true, tier: "cheap")
  end

  def claim!(record, key:, value:, facet: "summary")
    record.enliterator_claims.create!(key: key, value: value, status: "draft",
                                      tier: "cheap", visit: visit!(record, facet: facet))
  end

  let(:widget) { Widget.create!(title: "w", body: "the source text") }

  describe "the walk" do
    it "examines live engine-derived unlocked claims of the facet, aggregates per key via Audit.rate" do
      claim!(widget, key: "summary", value: "good one")
      claim!(widget, key: "summary", value: "bad one")
      claim!(widget, key: "keywords", value: "fine")
      claim!(widget, key: "other_facet", value: "x", facet: "authorship")   # other facet — out
      widget.assert_claim!(key: "host_fact", value: "h")                    # visit-less — out
      locked = claim!(widget, key: "anchored", value: "curator says")
      locked.update!(locked: true)                                          # curator ruling — out
      dead = claim!(widget, key: "dead", value: "gone")
      dead.update!(status: "superseded")                                    # not live — out

      stub = CensusExaminerStub.new("bad one" => "contradicted")
      report = described_class.run(facet: "summary", examiner: stub)

      expect(report[:examined]).to eq(3)
      expect(stub.calls.map { |c| c[:value] }).not_to include("x", "h", "curator says", "gone")
      expect(report[:counts]).to eq("supported" => 2, "contradicted" => 1)
      expect(report[:supported_rate]).to eq(Enliterator::Audit.rate(report[:counts]))
      expect(report[:per_key]["summary"][:supported_rate]).to eq(0.5)
      expect(report[:per_key]["keywords"][:supported_rate]).to eq(1.0)
    end

    it "WRITES NOTHING by default — no audit, no claim, no visit" do
      claim!(widget, key: "summary", value: "v")
      before = [ Enliterator::Audit.count, Enliterator::Claim.count, Enliterator::Visit.count ]
      described_class.run(facet: "summary", examiner: CensusExaminerStub.new)
      expect([ Enliterator::Audit.count, Enliterator::Claim.count, Enliterator::Visit.count ]).to eq(before)
    end

    it "splits visible/withheld when a partition callable is given" do
      visible_w  = Widget.create!(title: "pub", body: "text")
      withheld_w = Widget.create!(title: "priv", body: "text")
      claim!(visible_w,  key: "summary", value: "good one")
      claim!(withheld_w, key: "summary", value: "bad one")

      report = described_class.run(
        facet: "summary",
        examiner: CensusExaminerStub.new("bad one" => "unsupported"),
        visible: ->(record) { record.title == "pub" }
      )

      expect(report[:visibility][:visible][:supported_rate]).to eq(1.0)
      expect(report[:visibility][:withheld][:supported_rate]).to eq(0.0)
      expect(report[:per_key]["summary"][:visible][:examined]).to eq(1)
      expect(report[:per_key]["summary"][:withheld][:examined]).to eq(1)
    end

    it "counts blank sources as a condition line instead of silently skipping" do
      blank = Widget.create!(title: nil, body: nil)
      claim!(blank, key: "summary", value: "v")
      report = described_class.run(facet: "summary", examiner: CensusExaminerStub.new)
      expect(report[:blank_source]).to eq(1)
      expect(report[:examined]).to eq(0)
    end

    it "ABORTS loudly when the examiner is unavailable — a config problem is not weather" do
      claim!(widget, key: "summary", value: "v")
      stub = CensusExaminerStub.new("v" => :unavailable)
      expect {
        described_class.run(facet: "summary", examiner: stub)
      }.to raise_error(Enliterator::Census::ExaminerUnavailable, /Null adapter/)
    end

    it "collects per-claim exceptions and CONTINUES — one timeout must not void the walk" do
      w2 = Widget.create!(title: "w2", body: "text")
      claim!(widget, key: "summary", value: "boom")
      claim!(w2, key: "summary", value: "fine")
      stub = CensusExaminerStub.new("boom" => Timeout::Error)

      report = described_class.run(facet: "summary", examiner: stub)
      expect(report[:examined]).to eq(1)
      expect(report[:error_count]).to eq(1)
      expect(report[:errors].first).to include("Timeout::Error")
    end
  end

  describe "FLAG (defective verdicts filed as agent audits)" do
    it "files ONLY defective verdicts, as agent source, with the examine! source stamps" do
      claim!(widget, key: "summary", value: "good one")
      bad = claim!(widget, key: "summary", value: "bad one")

      expect {
        described_class.run(facet: "summary", flag: true,
                            examiner: CensusExaminerStub.new("bad one" => "contradicted"))
      }.to change(Enliterator::Audit, :count).by(1)

      audit = Enliterator::Audit.last
      expect(audit.claim).to eq(bad)
      expect(audit.source).to eq("agent")
      expect(audit.verdict).to eq("contradicted")
      expect(audit.auditor).to eq("census:stub:stub-model")
      full = widget.enliterator_text(facet: "summary")
      expect(audit.source_digest).to eq(Digest::MD5.hexdigest(full))
      expect(audit.source_chars).to eq(full.length)
      expect(audit.source_truncated).to be(false)
    end

    it "changes NO accuracy number — the v0.26 pin, mirrored" do
      c = claim!(widget, key: "summary", value: "bad one")
      Enliterator::Audit.create!(claim: c, verdict: "supported", source: "examiner")
      before = Enliterator::Audit.accuracy

      described_class.run(facet: "summary", flag: true,
                          examiner: CensusExaminerStub.new("bad one" => "unsupported"))
      expect(Enliterator::Audit.accuracy).to eq(before)
      # ...and the flagged claim STAYS in the examiner's sampling pool: an
      # agent flag must not remove it (only instrument audits do).
      unflagged = claim!(widget, key: "k2", value: "bad one")
      described_class.run(facet: "summary", key: "k2", flag: true,
                          examiner: CensusExaminerStub.new("bad one" => "unsupported"))
      expect(Enliterator::Audit.candidate_scope).to include(unflagged)
    end

    it "is idempotent by skip: already-flagged and human-settled claims are not re-filed" do
      flagged = claim!(widget, key: "k1", value: "bad one")
      Enliterator::Audit.create!(claim: flagged, verdict: "unsupported", source: "agent")
      settled = claim!(widget, key: "k2", value: "bad one")
      Enliterator::Audit.create!(claim: settled, verdict: "supported", source: "human")
      fresh = claim!(widget, key: "k3", value: "bad one")

      report = nil
      expect {
        report = described_class.run(facet: "summary", flag: true,
                                     examiner: CensusExaminerStub.new("bad one" => "unsupported"))
      }.to change(Enliterator::Audit, :count).by(1)   # only the fresh one

      expect(Enliterator::Audit.agent.where(claim: fresh).count).to eq(1)
      expect(report[:flags]).to include(found: 3, filed: 1, already_flagged: 1, human_settled: 1)
    end

    it "caps filings at flag_limit and REPORTS the truncation — never silent" do
      3.times { |i| claim!(widget, key: "k#{i}", value: "bad one") }
      report = nil
      expect {
        report = described_class.run(facet: "summary", flag: true, flag_limit: 2,
                                     examiner: CensusExaminerStub.new("bad one" => "unsupported"))
      }.to change(Enliterator::Audit, :count).by(2)
      expect(report[:flags]).to include(found: 3, filed: 2, over_limit: 1, limit: 2)
    end
  end
end
