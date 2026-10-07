# frozen_string_literal: true

require "rails_helper"

# v0.88 — INSTRUMENT AGREEMENT. Asked again about the same unchanged source,
# under the same configuration, does the examiner give the same verdict? A
# repeat measures the instrument, never the claim store: it is not an Audit.
RSpec.describe Enliterator::AuditRepeat do
  class RepeatExaminerStub
    def initialize(verdicts) = (@verdicts = verdicts.dup)
    def model_id = "stub-quality"
    def decide(messages:, schema:, tool_name:, tags: [])
      { "verdict" => @verdicts.shift || "supported", "rationale" => "r", "confidence" => 0.9 }
    end
  end

  around do |ex|
    prior = [ Enliterator.configuration.audit_evidence, Enliterator.configuration.audit_repeat_sample ]
    ex.run
    Enliterator.configuration.audit_evidence, Enliterator.configuration.audit_repeat_sample = prior
  end

  def audited!(title, verdict: "supported")
    w = Widget.create!(title: title, body: "a body about #{title}")
    visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    claim = w.enliterator_claims.create!(key: "finding", value: "about #{title}", status: "draft",
                                         confidence: 0.8, visit: visit)
    Enliterator::Audit.create!(claim: claim, verdict: verdict, source: "examiner", auditor: "quality:stub",
                               source_digest: Digest::MD5.hexdigest(w.enliterator_text(facet: "summary")))
  end

  def examiner(verdicts) = Enliterator::Audit::Examiner.new(llm: RepeatExaminerStub.new(verdicts), tier: "quality")

  it "re-examines, records agreement per facet, and never writes an audit" do
    3.times { |i| audited!("T#{i}") }
    expect {
      stats = described_class.run!(3, examiner: examiner(%w[supported unsupported supported]))
      expect(stats).to include(examined: 3, agreed: 2)
    }.not_to change(Enliterator::Audit, :count)
    expect(described_class.agreement["summary"]).to include(repeats: 3, agreed: 2, rate: 0.667, insufficient: true)
  end

  it "skips a claim whose source changed since the verdict — that would be terrain, not noise" do
    audit = audited!("Changed")
    audit.claim.tendable.update!(body: "rewritten")
    stats = described_class.run!(1, examiner: examiner(%w[supported]))
    expect(stats).to include(examined: 0, skipped_changed_source: 1)
  end

  it "only repeats verdicts rendered by the same tier and under the same evidence mode" do
    audited!("Other tier").update!(auditor: "cheap:stub")
    expect(described_class.run!(1, examiner: examiner(%w[supported]))[:examined]).to eq(0)

    Enliterator.configuration.audit_evidence = true
    audited!("Pre-evidence")                     # evidence_found nil = rendered without the requirement
    expect(described_class.run!(1, examiner: examiner(%w[supported]))[:examined]).to eq(0)
  end

  it "agreement never pools the two instruments" do
    audited!("A")
    described_class.run!(1, examiner: examiner(%w[supported]))
    Enliterator.configuration.audit_evidence = true
    expect(described_class.agreement).to eq({})
  end

  it "the accuracy tool reports it only once repeats exist" do
    expect(Enliterator::Mcp.dispatch("accuracy", {})).not_to have_key(:instrument_agreement)
    audited!("B")
    described_class.run!(1, examiner: examiner(%w[supported]))
    out = Enliterator::Mcp.dispatch("accuracy", {})
    expect(out[:instrument_agreement][:by_facet]["summary"]).to include(repeats: 1, rate: 1.0)
  end

  describe "the heartbeat" do
    it "0 (default): no repeat phase" do
      expect(described_class).not_to receive(:run!)
      Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
    end

    it "configured: repeats and records the tally on the cycle" do
      Enliterator.configuration.audit_repeat_sample = 2
      allow(described_class).to receive(:run!).and_return(examined: 2, agreed: 2, skipped_changed_source: 0)
      row = Enliterator::Heartbeat.beat!(budget: 10_000, skip_consider: true)
      expect(row.reload.audits["repeat"]).to include("examined" => 2, "agreed" => 2)
    end
  end
end
