# frozen_string_literal: true

require "rails_helper"

# v0.89 — carry human curation filed on an import target back to the
# authoring host. Simulated in one database: export, wipe the human audits
# (as a target would lose them), import — dry run, then apply.
RSpec.describe Enliterator::CurationTransfer do
  let(:file) { Rails.root.join("tmp", "curation-#{SecureRandom.hex(4)}.json").to_s }
  after { FileUtils.rm_f(file) }

  def claim!(record, key:, value:)
    visit = record.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    record.enliterator_claims.create!(key: key, value: value, status: "draft", confidence: 0.8, visit: visit)
  end

  def human!(claim, verdict, corrected: nil)
    Enliterator::Audit.create!(claim: claim, verdict: verdict, source: "human", auditor: "curator",
                               rationale: "checked", corrected_claim: corrected)
  end

  let(:w) { Widget.create!(title: "T", body: "b") }

  it "round-trips plain verdicts: dry run writes nothing, apply re-attaches with the original time" do
    c = claim!(w, key: "finding", value: "x")
    a = human!(c, "supported")
    stamp = a.created_at
    expect(described_class.export(file)).to eq(1)
    Enliterator::Audit.human.delete_all

    dry = described_class.import(file)
    expect(dry[:counts]).to eq("attach" => 1)
    expect(Enliterator::Audit.human.count).to eq(0)

    described_class.import(file, apply: true)
    back = Enliterator::Audit.human.sole
    expect(back).to have_attributes(claim_id: c.id, verdict: "supported", auditor: "curator", rationale: "checked")
    expect(back.created_at).to be_within(1).of(stamp)
    expect(described_class.import(file, apply: true)[:counts]).to eq("already_present" => 1)   # idempotent
  end

  it "re-mints a correction when the claim is still live here" do
    c = claim!(w, key: "finding", value: "wrong")
    fresh = w.correct_claim!(c, value: "right", note: "jr")
    human!(c, "contradicted", corrected: fresh)
    described_class.export(file)
    # Undo the correction locally, as the authoring host never saw it.
    Enliterator::Audit.human.delete_all
    c.update_columns(superseded_by_id: nil, status: "draft")
    fresh.delete

    out = described_class.import(file, apply: true)
    expect(out[:counts]).to eq("attach_correction" => 1)
    c.reload
    expect(c.superseded_by_id).to be_present
    successor = Enliterator::Claim.find(c.superseded_by_id)
    expect(successor).to have_attributes(value: "right", locked: true, attributed_to: "human:jr")
    expect(Enliterator::Audit.human.sole.corrected_claim_id).to eq(successor.id)
  end

  it "holds a correction whose claim was re-tended here — verdict recorded, correction reported" do
    c = claim!(w, key: "finding", value: "wrong")
    fresh = w.correct_claim!(c, value: "right")
    human!(c, "contradicted", corrected: fresh)
    described_class.export(file)
    Enliterator::Audit.human.delete_all
    # Here, a re-tend superseded the claim with something else entirely.
    c.update_columns(superseded_by_id: nil, status: "draft")
    fresh.delete
    retend = claim!(w, key: "finding", value: "re-tended")
    c.supersede!(retend)

    out = described_class.import(file, apply: true)
    expect(out[:counts]).to eq("correction_held" => 1)
    expect(out[:rows].first[:held_correction]).to include("kind" => "correct", "value" => "right")
    expect(Enliterator::Audit.human.sole.corrected_claim_id).to be_nil
    expect(retend.reload.superseded_by_id).to be_nil            # the successor is untouched
  end

  it "re-mints a retraction as an adjudicated absence" do
    c = claim!(w, key: "advisor", value: "Nobody")
    blank = w.adjudicate_absent!(c, key: "advisor", context: nil, note: nil)
    human!(c, "unsupported", corrected: blank)
    described_class.export(file)
    Enliterator::Audit.human.delete_all
    c.update_columns(superseded_by_id: nil, status: "draft")
    blank.delete

    expect(described_class.import(file, apply: true)[:counts]).to eq("attach_correction" => 1)
    expect(Enliterator::Claim.blank_value?(Enliterator::Claim.find(c.reload.superseded_by_id).value)).to be(true)
  end

  it "a claim that doesn't match here is reported, nothing written" do
    c = claim!(w, key: "finding", value: "x")
    human!(c, "supported")
    described_class.export(file)
    Enliterator::Audit.human.delete_all
    c.update_columns(value: "different now")

    expect(described_class.import(file, apply: true)[:counts]).to eq("unmatched" => 1)
    expect(Enliterator::Audit.human.count).to eq(0)
  end

  it "matches by fingerprint when the id has moved" do
    c = claim!(w, key: "finding", value: "x")
    human!(c, "supported")
    described_class.export(file)
    Enliterator::Audit.human.delete_all
    data = JSON.parse(File.read(file))
    data["audits"].first["claim_id"] = 9_999_999
    File.write(file, JSON.generate(data))

    expect(described_class.import(file, apply: true)[:counts]).to eq("attach" => 1)
    expect(Enliterator::Audit.human.sole.claim_id).to eq(c.id)
  end
end
