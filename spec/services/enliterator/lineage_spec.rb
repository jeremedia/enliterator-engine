# frozen_string_literal: true

require "rails_helper"

# v0.90 — ONE PLACE CURATES, BY LINEAGE. An import marks its database as a
# copy; a copy refuses curation writes unless config says otherwise or a
# curator declares it the authority. The import guard counts only verdicts
# filed AFTER the last import — verdicts that arrived with an import came from
# the source. A database never imported is byte-identical.
RSpec.describe "v0.90 lineage" do
  let(:archive) { Rails.root.join("tmp", "lineage-#{SecureRandom.hex(4)}.tar").to_s }
  after { FileUtils.rm_f(archive) }

  around do |ex|
    prior = [ Enliterator.configuration.curation_writes, Enliterator.configuration.curation_home,
              Enliterator.configuration.deployment_label ]
    ex.run
    Enliterator.configuration.curation_writes, Enliterator.configuration.curation_home,
      Enliterator.configuration.deployment_label = prior
  end

  def claim_with_human_verdict!
    w = Widget.create!(title: "T", body: "b")
    visit = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true, tier: "cheap")
    c = w.enliterator_claims.create!(key: "finding", value: "x", status: "draft", confidence: 0.8, visit: visit)
    Enliterator::Audit.create!(claim: c, verdict: "supported", source: "human", auditor: "curator")
    c
  end

  it "a database never imported is the authority — curation allowed, byte-identical" do
    expect(Enliterator::LineageEvent.copy?).to be(false)
    expect(Enliterator.curation_writes?).to be(true)
  end

  it "exports carry exported_from; an import records the copy and refuses curation by default" do
    Enliterator.configuration.deployment_label = "HSDL:development"
    claim_with_human_verdict!
    manifest = Enliterator::Portability.export(archive)
    expect(manifest["exported_from"]).to eq("HSDL:development")

    Enliterator::Portability.import(archive, force: true, discard_audits: true)
    expect(Enliterator::LineageEvent.copy?).to be(true)
    expect(Enliterator::LineageEvent.last_import.source_label).to eq("HSDL:development")
    expect(Enliterator.curation_writes?).to be(false)
    expect(Enliterator.curation_refusal).to include("copy of HSDL:development", "made at HSDL:development")
  end

  it "the lineage survives the next import (target-local) and is never exported" do
    claim_with_human_verdict!
    Enliterator::Portability.export(archive)
    Enliterator::Portability.import(archive, force: true, discard_audits: true)
    manifest = Enliterator::Portability.export(archive)
    expect(manifest["tables"]).not_to have_key("enliterator_lineage_events")
    Enliterator::Portability.import(archive, force: true)
    expect(Enliterator::LineageEvent.where(kind: "import").count).to eq(2)
  end

  it "the guard counts only verdicts filed since the last import — imported verdicts don't block" do
    claim_with_human_verdict!
    Enliterator::Portability.export(archive)
    Enliterator::Portability.import(archive, force: true, discard_audits: true)   # first import: no marker yet

    # The imported human verdict came from the source — it must not block the next import.
    expect { Enliterator::Portability.import(archive, force: true) }.not_to raise_error

    # A verdict filed HERE after the import does.
    Enliterator::Audit.create!(claim: Enliterator::Claim.first, verdict: "contradicted", source: "human",
                               auditor: "curator")
    expect { Enliterator::Portability.import(archive, force: true) }
      .to raise_error(Enliterator::Portability::TargetCurationAtRisk, /1 human audit verdict\(s\) filed since its last import/)
  end

  it "declaring authority makes a copy curate; explicit config still wins either way" do
    Enliterator::LineageEvent.record_import!("exported_from" => "src", "generated_at" => Time.current.iso8601)
    expect(Enliterator.curation_writes?).to be(false)

    Enliterator.configuration.curation_writes = true
    expect(Enliterator.curation_writes?).to be(true)
    Enliterator.configuration.curation_writes = nil

    Enliterator::LineageEvent.declare_authority!(note: "promoted")
    expect(Enliterator.curation_writes?).to be(true)
    Enliterator.configuration.curation_writes = false
    expect(Enliterator.curation_writes?).to be(false)
  end
end
