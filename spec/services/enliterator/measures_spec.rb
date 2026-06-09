require "rails_helper"

# The :completeness measure is the engine's built-in quality scorer. It checks a
# small expected set — a live claim, a primary embedding, a succeeded visit — and
# scores the fraction present in [0, 1]. This spec proves the score climbs as a
# record accrues each signal, which is the whole point of a quality measure: it
# tells a host how literate a record has become.
RSpec.describe Enliterator::Measures do
  let(:widget) { Widget.create!(title: "Acme", body: "A useful thing.") }

  # Ensure the built-in measure is registered for every example, independent of
  # whatever order other specs ran in (the registry is process-global).
  before { described_class.load_default! }

  # Fetch the persisted :completeness Measure row for a tendable.
  def completeness_for(tendable)
    tendable.enliterator_measures.find_by(name: "completeness")
  end

  # --- signal builders (each adds exactly one of the three expected signals) ---

  def add_live_claim(tendable)
    Enliterator::Claim.create!(
      tendable: tendable,
      key:      "summary",
      value:    "A useful thing.",
      status:   "draft" # live = current AND not superseded
    )
  end

  def add_primary_embedding(tendable)
    dims = Enliterator.configuration.default_embedding_dimensions
    Enliterator::Embedding.create!(
      embeddable: tendable,
      kind:       "primary",
      embedding:  Array.new(dims, 0.0),
      dimensions: dims,
      model:      "null"
    )
  end

  def add_succeeded_visit(tendable)
    Enliterator::Visit.create!(
      tendable:    tendable,
      facet:      "summary",
      status:      "succeeded",
      finished_at: Time.current
    )
  end

  describe ":completeness measure" do
    it "is registered idempotently as a default" do
      expect(described_class.registry).to have_key(:completeness)
      # Calling load_default! again must not duplicate or replace it.
      block = described_class.registry[:completeness]
      described_class.load_default!
      expect(described_class.registry[:completeness]).to equal(block)
    end

    it "scores 0.0 for a bare record with none of the expected signals" do
      described_class.recompute!(widget)

      measure = completeness_for(widget)
      expect(measure).to be_present
      expect(measure.name).to eq("completeness")
      expect(measure.score).to eq(0.0)
      expect(measure.computed_at).to be_present
    end

    it "documents each expected signal in the signals hash" do
      described_class.recompute!(widget)

      signals = completeness_for(widget).signals
      expect(signals.keys).to match_array(
        %w[has_live_claim has_primary_embedding has_succeeded_visit]
      )
      # Every signal is absent (false) on a bare record, each weighted 1.0.
      signals.each_value do |s|
        expect(s["value"]).to eq(false)
        expect(s["weight"]).to eq(1.0)
      end
    end

    it "rises from 0 toward 1 as each expected signal appears" do
      # 0/3 — nothing present yet.
      described_class.recompute!(widget)
      expect(completeness_for(widget).score).to eq(0.0)

      # 1/3 — a live claim.
      add_live_claim(widget)
      described_class.recompute!(widget)
      expect(completeness_for(widget).score).to be_within(1e-9).of(1.0 / 3)

      # 2/3 — plus a primary embedding.
      add_primary_embedding(widget)
      described_class.recompute!(widget)
      expect(completeness_for(widget).score).to be_within(1e-9).of(2.0 / 3)

      # 3/3 — plus a succeeded visit.
      add_succeeded_visit(widget)
      described_class.recompute!(widget)
      expect(completeness_for(widget).score).to eq(1.0)
    end

    it "reflects the live signals in the signals hash at full completeness" do
      add_live_claim(widget)
      add_primary_embedding(widget)
      add_succeeded_visit(widget)
      described_class.recompute!(widget)

      signals = completeness_for(widget).signals
      expect(signals["has_live_claim"]["value"]).to eq(true)
      expect(signals["has_primary_embedding"]["value"]).to eq(true)
      expect(signals["has_succeeded_visit"]["value"]).to eq(true)
    end

    it "upserts a single measure row across recomputations (no duplicates)" do
      described_class.recompute!(widget)
      add_live_claim(widget)
      described_class.recompute!(widget)

      rows = widget.enliterator_measures.where(name: "completeness")
      expect(rows.count).to eq(1)
      expect(rows.first.score).to be_within(1e-9).of(1.0 / 3)
    end

    it "does not count a superseded claim as a live signal" do
      claim = add_live_claim(widget)
      # Tombstone it (a DELETE supersedes without a replacement) — no longer live.
      claim.update!(status: "superseded")

      described_class.recompute!(widget)
      expect(completeness_for(widget).score).to eq(0.0)
      expect(completeness_for(widget).signals["has_live_claim"]["value"]).to eq(false)
    end

    it "does not count a non-primary embedding as the primary signal" do
      dims = Enliterator.configuration.default_embedding_dimensions
      Enliterator::Embedding.create!(
        embeddable: widget,
        kind:       "full_text",
        embedding:  Array.new(dims, 0.0),
        dimensions: dims,
        model:      "null"
      )

      described_class.recompute!(widget)
      expect(completeness_for(widget).signals["has_primary_embedding"]["value"]).to eq(false)
    end

    it "does not count a non-succeeded visit as the visit signal" do
      Enliterator::Visit.create!(tendable: widget, facet: "summary", status: "running")

      described_class.recompute!(widget)
      expect(completeness_for(widget).signals["has_succeeded_visit"]["value"]).to eq(false)
    end
  end

  describe ".recompute!" do
    it "returns the persisted Measure records it computed" do
      result = described_class.recompute!(widget)

      expect(result).to all(be_a(Enliterator::Measure))
      expect(result.map(&:name)).to include("completeness")
      expect(result).to all(be_persisted)
    end
  end
end
