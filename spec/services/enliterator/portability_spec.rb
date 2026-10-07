# frozen_string_literal: true

require "rails_helper"

# v0.22 — Portability: the enliteration as a movable asset. Export everything
# learned into one archive; import it verbatim on a fresh deployment —
# provenance chains intact, sequences continuing after the imported history.
RSpec.describe Enliterator::Portability do
  let(:archive) { Rails.root.join("tmp", "portability_spec.tar").to_s }
  after { FileUtils.rm_f(archive) }

  def seed!
    ctx = Enliterator::Context.create!(key: "spec-ctx", name: "Spec Context")
    w   = Widget.create!(title: "Ported Widget", body: "b")
    w.place_in_context!(ctx) if w.respond_to?(:place_in_context!)
    hb  = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1000,
                                         planned: { "counts" => {} }, started_at: Time.current)
    v   = w.enliterator_visits.create!(facet: "summary", status: "succeeded", applied: true,
                                       tier: "cheap", heartbeat: hb)
    old = w.enliterator_claims.create!(key: "summary", value: "first take", status: "draft", visit: v)
    new_claim = w.enliterator_claims.create!(key: "summary", value: "second take", status: "draft", visit: v)
    old.supersede!(new_claim)
    Enliterator::Audit.create!(claim: new_claim, verdict: "supported", source: "examiner")
    Enliterator::Suggestion.create!(tendable: w, facet: "summary", proposed_key: "extra_key",
                                    rationale: "spec", status: "pending")
    Enliterator::Measure.create!(tendable: w, name: "condition", score: 1.0, signals: {},
                                 computed_at: Time.current)
    { context: ctx, widget: w, heartbeat: hb, visit: v, old: old, claim: new_claim }
  end

  def wipe!
    conn = ActiveRecord::Base.connection
    conn.execute("TRUNCATE #{conn.tables.grep(/\Aenliterator_/).join(', ')} RESTART IDENTITY")
  end

  it "round-trips: export → wipe → import, with provenance chains and ids intact" do
    seeded = seed!
    manifest = described_class.export(archive)
    expect(manifest["tables"]["enliterator_claims"]["rows"]).to eq(2)
    expect(manifest["excluded"]).to eq([ "enliterator_measures" ])

    claim_id = seeded[:claim].id
    wipe!
    expect(Enliterator::Claim.count).to eq(0)

    described_class.import(archive)
    claim = Enliterator::Claim.find(claim_id)               # same id — provenance preserved
    expect(claim.value).to eq("second take")
    expect(claim.visit_id).to eq(seeded[:visit].id)
    expect(seeded[:old].reload.superseded_by_id).to eq(claim.id)   # the chain survived
    expect(Enliterator::Audit.where(claim_id: claim.id).count).to eq(1)
    expect(Enliterator::Suggestion.where(proposed_key: "extra_key")).to exist
    expect(Enliterator::Context.find_by(key: "spec-ctx")).to be_present
  end

  it "sequences continue AFTER the imported history (the next heartbeat numbers after dev's)" do
    seeded = seed!
    described_class.export(archive)
    wipe!
    described_class.import(archive)
    next_hb = Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1, planned: {},
                                             started_at: Time.current)
    expect(next_hb.id).to be > seeded[:heartbeat].id
  end

  it "excludes the condition register by default and includes it with measures: true" do
    seed!
    described_class.export(archive)
    wipe!
    described_class.import(archive)
    expect(Enliterator::Measure.count).to eq(0)             # re-derive locally, honestly

    wipe!
    seed!
    described_class.export(archive, measures: true)
    wipe!
    manifest = described_class.import(archive)
    expect(manifest["excluded"]).to eq([])
    expect(Enliterator::Measure.count).to eq(1)
  end

  it "refuses a non-empty target without force, and replaces with it" do
    seed!
    described_class.export(archive)
    expect { described_class.import(archive) }
      .to raise_error(ArgumentError, /target is not empty.*force/m)

    described_class.import(archive, force: true)
    expect(Enliterator::Claim.count).to eq(2)
  end

  it "aborts by name on schema skew instead of loading crooked data" do
    seed!
    described_class.export(archive)
    manifest = described_class.read_manifest(archive)
    manifest["tables"]["enliterator_claims"]["columns"] << "phantom_column"
    allow(described_class).to receive(:read_manifest).and_return(manifest)
    wipe!
    expect { described_class.import(archive) }
      .to raise_error(ArgumentError, /enliterator_claims: column mismatch.*version skew/m)
  end

  it "imports one table at a time (the maintenance-task entry point)" do
    seed!
    described_class.export(archive)
    wipe!
    described_class.import_table(archive, "enliterator_contexts", skip_guard: true)
    expect(Enliterator::Context.find_by(key: "spec-ctx")).to be_present
    expect(Enliterator::Claim.count).to eq(0)
  end

  # v0.81 — what a deployment did with the engine stays with that deployment.
  describe "target-local tables (v0.81)" do
    def desk_history!(token, question)
      conv = Enliterator::Chat::Conversation.create!(token: token)
      Enliterator::Chat::Turn.create!(conversation: conv, ordinal: 0, question: question)
      Enliterator::Chat::Persona.record(desk_name: "Frontdesk", system_prompt: "#{token} voice")
      conv
    end

    it "never exports the Reference Desk's history" do
      seed!
      desk_history!("dev-token", "a dev question")
      manifest = described_class.export(archive)
      expect(manifest["tables"].keys).not_to include(*described_class::TARGET_LOCAL)
      expect(manifest["target_local"]).to eq(described_class::TARGET_LOCAL)
    end

    it "a forced import keeps the TARGET's own desk history (the HSDL prod overwrite)" do
      seed!
      described_class.export(archive)
      wipe!
      seed!                                            # the target has its own enliteration...
      desk_history!("prod-token", "a patron question") # ...and its own desk history

      described_class.import(archive, force: true)
      expect(Enliterator::Claim.count).to eq(2)        # the enliteration was replaced
      expect(Enliterator::Chat::Conversation.pluck(:token)).to eq([ "prod-token" ])
      expect(Enliterator::Chat::Turn.pluck(:question)).to eq([ "a patron question" ])
      expect(Enliterator::Chat::Persona.pluck(:system_prompt)).to eq([ "prod-token voice" ])
    end

    it "desk history alone does not make a target 'non-empty'" do
      seed!
      described_class.export(archive)
      wipe!
      desk_history!("prod-token", "a patron question")
      expect { described_class.import(archive) }.not_to raise_error
      expect(Enliterator::Chat::Conversation.count).to eq(1)
    end

    it "skips target-local tables carried by an OLDER archive, by name, on every entry point" do
      seed!
      desk_history!("dev-token", "a dev question")
      # simulate a pre-v0.81 archive: export with the old (everything) table set
      allow(described_class).to receive(:transferable_tables).and_wrap_original do |m, conn|
        described_class.engine_tables(conn)
      end
      described_class.export(archive)
      manifest = described_class.read_manifest(archive)
      expect(manifest["tables"].keys).to include("enliterator_chat_turns")
      RSpec::Mocks.space.proxy_for(described_class).reset

      wipe!
      desk_history!("prod-token", "a patron question")
      described_class.import(archive)
      expect(described_class.import_table(archive, "enliterator_chat_turns", skip_guard: true)).to eq(0)
      expect(described_class.importable_tables(manifest)).not_to include(*described_class::TARGET_LOCAL)
      expect(Enliterator::Chat::Conversation.pluck(:token)).to eq([ "prod-token" ])
    end
  end

  describe "human audits on the target (v0.81)" do
    it "refuses a forced replace that would discard the target's human verdicts — loudly, by count" do
      seed!
      described_class.export(archive)
      Enliterator::Audit.create!(claim: Enliterator::Claim.first, verdict: "contradicted", source: "human")

      expect { described_class.import(archive, force: true) }
        .to raise_error(described_class::TargetCurationAtRisk, /1 human audit verdict/)
      expect(Enliterator::Audit.human.count).to eq(1)  # nothing was touched
    end

    it "proceeds when the loss is a decision (discard_audits: true)" do
      seed!
      described_class.export(archive)
      Enliterator::Audit.create!(claim: Enliterator::Claim.first, verdict: "contradicted", source: "human")

      described_class.import(archive, force: true, discard_audits: true)
      expect(Enliterator::Audit.human.count).to eq(0)
      expect(Enliterator::Audit.count).to eq(1)        # the archive's examiner audit
    end

    it "examiner-only audits never block a replace" do
      seed!
      described_class.export(archive)
      expect { described_class.import(archive, force: true) }.not_to raise_error
    end
  end
end
