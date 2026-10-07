# frozen_string_literal: true

require "rails_helper"

# v0.87 — A VERDICT CARRIES ITS EVIDENCE. With `config.audit_evidence` on, the
# examiner must quote the source passage that decides its verdict; the engine
# checks the quote against the source it examined ("…"-tolerant) and records
# the quote, whether it was found, and the basis of the text it sits in. No
# verdict is rewritten: an unfound quote is recorded as unfound. Off: the
# pre-v0.87 prompt, schema and row, byte-identical.
RSpec.describe "v0.87 audit evidence" do
  class EvidenceExaminerStub
    attr_reader :last_schema, :last_messages
    def initialize(evidence:, verdict: "supported")
      @evidence = evidence
      @verdict = verdict
    end
    def model_id = "stub-quality"
    def decide(messages:, schema:, tool_name:, tags: [])
      @last_schema = schema
      @last_messages = messages
      { "verdict" => @verdict, "rationale" => "r", "confidence" => 0.9, "evidence" => @evidence }
    end
  end

  around do |ex|
    prior = Enliterator.configuration.audit_evidence
    ex.run
    Enliterator.configuration.audit_evidence = prior
  end

  let(:body) do
    "County clerks kept counting through redundant tabulation systems. " \
    "Statutory fallback procedures governed every recount in the state."
  end
  let(:widget) { Widget.create!(title: "Continuity", body: body) }
  let(:claim) do
    visit = widget.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    widget.enliterator_claims.create!(key: "finding", value: "clerks relied on redundant tabulation",
                                      status: "draft", confidence: 0.8, visit: visit)
  end

  def examine(stub) = Enliterator::Audit::Examiner.new(llm: stub).examine!(claim)

  it "OFF: the pre-v0.87 schema, prompt and row" do
    stub = EvidenceExaminerStub.new(evidence: "ignored")
    audit = examine(stub)
    expect(stub.last_schema["properties"]).not_to have_key("evidence")
    expect(stub.last_messages.first[:content]).not_to include("GROUND YOUR VERDICT")
    expect(audit.evidence).to be_nil
    expect(audit.evidence_found).to be_nil
    expect(audit.evidence_basis).to be_nil
  end

  it "ON: asks for the quote, finds it in the source, records where it sits" do
    Enliterator.configuration.audit_evidence = true
    stub = EvidenceExaminerStub.new(evidence: "County clerks kept counting through redundant tabulation systems.")
    audit = examine(stub)
    expect(stub.last_schema["properties"]).to have_key("evidence")
    expect(stub.last_messages.first[:content]).to include("GROUND YOUR VERDICT")
    expect(audit).to have_attributes(evidence_found: true, evidence_basis: "undeclared", verdict: "supported")
    expect(audit.evidence).to start_with("County clerks")
  end

  it "tolerates an ellipsis between fragments, in order" do
    Enliterator.configuration.audit_evidence = true
    audit = examine(EvidenceExaminerStub.new(
      evidence: "kept counting through redundant tabulation … fallback procedures governed every recount"
    ))
    expect(audit.evidence_found).to be(true)
  end

  it "an invented or paraphrased quote is recorded as NOT found — the verdict is not rewritten" do
    Enliterator.configuration.audit_evidence = true
    audit = examine(EvidenceExaminerStub.new(evidence: "Clerks relied heavily on backup counting machines statewide."))
    expect(audit).to have_attributes(evidence_found: false, evidence_basis: nil, verdict: "supported")
  end

  it "a quote in the engine's reading notes is labelled reading_notes" do
    Enliterator.configuration.audit_evidence = true
    widget.update!(body: "#{body}\n\n#{Enliterator::Part::NOTEBOOK_HEADER}\n\n## Method\n" \
                         "argument: the clerks' redundancy carried the count through the outage")
    audit = examine(EvidenceExaminerStub.new(evidence: "the clerks' redundancy carried the count through the outage"))
    expect(audit).to have_attributes(evidence_found: true, evidence_basis: "reading_notes")
  end

  it "provenance serves the evidence; pre-v0.87 audits carry no evidence keys" do
    old = examine(EvidenceExaminerStub.new(evidence: "x"))
    Enliterator.configuration.audit_evidence = true
    examine(EvidenceExaminerStub.new(evidence: "Statutory fallback procedures governed every recount in the state."))
    audits = Enliterator::Mcp.dispatch("provenance", "claim_id" => claim.id)[:audits]
    expect(audits.first.keys).not_to include(:evidence, :evidence_found)
    expect(audits.last).to include(evidence_found: true, evidence_basis: "undeclared")
    expect(old.evidence_found).to be_nil
  end

  it "an empty quote (unsupported) is recorded as no evidence" do
    Enliterator.configuration.audit_evidence = true
    audit = examine(EvidenceExaminerStub.new(evidence: "", verdict: "unsupported"))
    expect(audit).to have_attributes(evidence: nil, evidence_found: false, verdict: "unsupported")
  end
end
