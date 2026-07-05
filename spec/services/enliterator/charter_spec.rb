# frozen_string_literal: true

require "rails_helper"

# v0.57 — the charter's telling half: the collection's extrinsic identity as
# human-attributed claims on the one-row collection tendable; untold fields as
# visit-less lacunae; edits as auditable supersessions.
RSpec.describe Enliterator::Charter do
  let!(:library) { Library.create!(name: "Test Library") }

  def configure!
    Enliterator.configure { |c| c.collection_tendable = "Library" }
  end

  describe "record resolution" do
    it "is unconfigured by default — byte-identical posture" do
      expect(described_class.configured?).to be false
      expect(described_class.read).to be_nil
    end

    it "raises actionably on a typo'd constant" do
      Enliterator.configure { |c| c.collection_tendable = "Wrokshop" }
      expect { described_class.record }
        .to raise_error(Enliterator::ConfigurationError, /does not name a constant/)
    end

    it "returns nil for zero rows (the legit deploy window — loudness lives in the heartbeat/rake)" do
      library.destroy!
      configure!
      expect(described_class.record).to be_nil
      expect(described_class.read).to be_nil
    end

    it "raises on more than one row — the identity cannot be ambiguous" do
      Library.create!(name: "Impostor")
      configure!
      expect { described_class.record }
        .to raise_error(Enliterator::ConfigurationError, /exactly one row/)
    end
  end

  describe "the auto-mask (a collection tendable is by definition synthesized)" do
    it "folds collection_tendable into synthesized_tendable_names" do
      configure!
      expect(Enliterator.synthesized_tendable_names).to include("Library")
      expect(Enliterator.mask_synthesized(%w[Widget Library])).to eq(%w[Widget])
    end

    it "unset ⇒ nothing folds (byte-identical)" do
      expect(Enliterator.synthesized_tendable_names).to eq([])
    end
  end

  describe ".tell! / .read" do
    before { configure! }

    it "creates human-attributed claims that enter .understanding, and reads them back" do
      described_class.tell!(proper_noun: "Spine", identity: "a workshop", by: "jeremy")
      c = described_class.read
      expect(c[:told]).to eq(proper_noun: "Spine", identity: "a workshop")
      expect(c[:untold]).to contain_exactly("purpose", "audience")

      claim = library.enliterator_claims.live.find_by(key: "charter_proper_noun")
      expect(claim.attributed_to).to eq("human:jeremy")
      expect(claim.locked).to be true
      expect(Enliterator::Claim.understanding).to include(claim)
    end

    it "an equal re-tell NOOPs (no redundant supersession)" do
      described_class.tell!(purpose: "writing books")
      expect {
        result = described_class.tell!(purpose: "writing books")
        expect(result[:purpose]).to eq(:unchanged)
      }.not_to change { library.enliterator_claims.count }
    end

    it "a changed value SUPERSEDES — the identity document's history is auditable" do
      described_class.tell!(purpose: "writing books", by: "jeremy")
      described_class.tell!(purpose: "writing and tending books", by: "jeremy")

      chain = library.enliterator_claims.where(key: "charter_purpose").order(:id)
      expect(chain.count).to eq(2)
      expect(chain.first.status).to eq("superseded")
      expect(chain.first.superseded_by_id).to eq(chain.last.id)
      expect(chain.last.value).to eq("writing and tending books")
      expect(described_class.read[:told][:purpose]).to eq("writing and tending books")
    end

    it "exposes the DERIVED operational values without storing them as claims" do
      c = described_class.read
      expect(c[:derived]).to have_key(:reading_scope)
      expect(c[:derived]).to have_key(:reading_facets)
      expect(library.enliterator_claims.where("key LIKE 'charter_reading%'")).to be_empty
    end

    it "headline joins proper noun and identity" do
      described_class.tell!(proper_noun: "Spine", identity: "a workshop of sovereign manuscripts")
      expect(described_class.headline).to eq("Spine — a workshop of sovereign manuscripts")
    end
  end

  describe ".reconcile_gaps! (untold identity = open, named gaps)" do
    before { configure! }

    it "opens a visit-less silent lacuna per untold field — the reserved nullability in use" do
      result = described_class.reconcile_gaps!
      expect(result[:opened]).to eq(4)

      gaps = library.enliterator_lacunae.open.where(facet: "charter")
      expect(gaps.count).to eq(4)
      gap = gaps.find_by(key: "charter_proper_noun")
      expect(gap.diagnosis).to eq("silent")
      expect(gap.detected_in_visit_id).to be_nil
    end

    it "telling a field closes its lacuna; reconcile closes told stragglers" do
      described_class.reconcile_gaps!
      described_class.tell!(proper_noun: "Spine")
      expect(library.enliterator_lacunae.open.where(key: "charter_proper_noun")).to be_empty
      expect(library.enliterator_lacunae.open.where(facet: "charter").count).to eq(3)
    end

    it "is idempotent — a second pass refreshes rather than duplicates" do
      described_class.reconcile_gaps!
      expect { described_class.reconcile_gaps! }
        .not_to change { library.enliterator_lacunae.open.count }
    end
  end

  describe "the heartbeat step (Heartbeat#reconcile_charter!)" do
    let(:beat) do
      Enliterator::Heartbeat.create!(mode: "sync", budget_tokens: 1000,
                                     started_at: Time.current, planned: { "items" => [] })
    end

    it "unconfigured: never pulses — the phase trace stays byte-identical" do
      before_phase = beat.reload.phase
      warnings = []
      beat.send(:reconcile_charter!, warnings)
      expect(beat.reload.phase).to eq(before_phase)
      expect(warnings).to eq([])
    end

    it "configured: pulses the charter phase and reconciles the gaps" do
      configure!
      warnings = []
      beat.send(:reconcile_charter!, warnings)
      expect(beat.reload.phase).to eq("charter")
      expect(library.enliterator_lacunae.open.where(facet: "charter").count).to eq(4)
      expect(warnings).to eq([])
    end

    it "configured but unseeded: the ledger is the loud channel" do
      library.destroy!
      configure!
      warnings = []
      beat.send(:reconcile_charter!, warnings)
      expect(warnings.join).to include("no Library row exists")
    end
  end
end
