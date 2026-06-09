require "rails_helper"

# Enliterator::Tendable is the concern a host model includes to become literate.
# Including it wires the four polymorphic associations, registers the model in
# Enliterator.tendable_models (so the scheduled walk can find it), and provides
# literacy_state — the compounding context handed to each visit. The dummy Widget
# host (spec/dummy) includes the concern and defines to_enliterator_text.
RSpec.describe Enliterator::Tendable do
  let(:widget) { Widget.create!(title: "Acme", body: "A widget.") }

  describe "registration" do
    it "registers the host model in Enliterator.tendable_models" do
      # Widget includes the concern at load time, so it is already registered.
      expect(Enliterator.tendable_models).to include(Widget)
    end

    it "exposes the class predicate" do
      expect(Widget.enliterator_tendable?).to be(true)
    end
  end

  describe "associations" do
    it "has_many enliterator_visits as a polymorphic tendable" do
      visit = Enliterator::Visit.create!(tendable: widget, facet: "summary", status: "pending")
      expect(widget.enliterator_visits).to include(visit)
      expect(visit.tendable).to eq(widget)
    end

    it "has_many enliterator_claims as a polymorphic tendable" do
      claim = Enliterator::Claim.create!(tendable: widget, key: "summary", value: "v")
      expect(widget.enliterator_claims).to include(claim)
      expect(claim.tendable).to eq(widget)
    end

    it "has_many enliterator_measures as a polymorphic tendable" do
      measure = Enliterator::Measure.create!(tendable: widget, name: "completeness", score: 0.0)
      expect(widget.enliterator_measures).to include(measure)
      expect(measure.tendable).to eq(widget)
    end

    it "has_many enliterator_embeddings as a polymorphic embeddable" do
      embedder = Enliterator::Adapters::Embedder::Null.new
      embedding = Enliterator::Embedding.create!(
        embeddable: widget,
        kind:       "primary",
        embedding:  embedder.embed("Acme"),
        dimensions: embedder.dimensions
      )
      expect(widget.enliterator_embeddings).to include(embedding)
      expect(embedding.embeddable).to eq(widget)
    end

    it "destroys dependent enliterator records when the host is destroyed" do
      Enliterator::Visit.create!(tendable: widget, facet: "summary", status: "pending")
      Enliterator::Claim.create!(tendable: widget, key: "summary", value: "v")
      Enliterator::Measure.create!(tendable: widget, name: "completeness", score: 0.0)
      Enliterator::Embedding.create!(
        embeddable: widget,
        kind:       "primary",
        embedding:  Enliterator::Adapters::Embedder::Null.new.embed("Acme")
      )

      expect { widget.destroy }
        .to change(Enliterator::Visit, :count).by(-1)
        .and change(Enliterator::Claim, :count).by(-1)
        .and change(Enliterator::Measure, :count).by(-1)
        .and change(Enliterator::Embedding, :count).by(-1)
    end
  end

  describe "#enliterator_text" do
    it "uses the host's to_enliterator_text override" do
      expect(widget.enliterator_text).to eq("Acme\nA widget.")
    end
  end

  describe "#literacy_state" do
    it "returns the compounding-context shape: claims, recent_visits, measures" do
      state = widget.literacy_state(facet: "summary")

      expect(state).to be_a(Hash)
      expect(state.keys).to contain_exactly(:claims, :recent_visits, :measures)
      expect(state[:claims]).to eq([])
      expect(state[:recent_visits]).to eq([])
      expect(state[:measures]).to eq({})
    end

    it "includes only LIVE claims, projected via to_state" do
      live       = Enliterator::Claim.create!(tendable: widget, key: "summary", value: "kept", status: "draft")
      superseded = Enliterator::Claim.create!(tendable: widget, key: "old", value: "gone", status: "superseded")

      state = widget.literacy_state(facet: "summary")

      keys = state[:claims].map { |c| c[:key] }
      expect(keys).to include(live.key)
      expect(keys).not_to include(superseded.key)
      # to_state projection, not raw records.
      expect(state[:claims].first).to include(:key, :value, :confidence, :status, :locked)
    end

    it "includes recent visits for the given facet, projected via to_state" do
      visit = Enliterator::Visit.create!(
        tendable:       widget,
        facet:         "summary",
        status:         "succeeded",
        confidence:     0.7,
        reconciliation: { "added" => [ "summary" ] }
      )
      Enliterator::Visit.create!(tendable: widget, facet: "other", status: "succeeded")

      state = widget.literacy_state(facet: "summary")

      expect(state[:recent_visits].size).to eq(1)
      projected = state[:recent_visits].first
      expect(projected[:facet]).to eq(visit.facet)
      expect(projected).to include(:facet, :confidence, :summary, :at)
    end

    it "maps measures by name to score" do
      Enliterator::Measure.create!(tendable: widget, name: "completeness", score: 0.5)

      state = widget.literacy_state(facet: "summary")

      expect(state[:measures]).to eq("completeness" => 0.5)
    end
  end

  describe "#last_tended_at" do
    it "returns nil when there are no succeeded visits" do
      expect(widget.last_tended_at).to be_nil
    end

    it "returns the newest succeeded visit's finished_at, scoped by facet" do
      older = Enliterator::Visit.create!(tendable: widget, facet: "summary", status: "succeeded", finished_at: 2.days.ago)
      newer = Enliterator::Visit.create!(tendable: widget, facet: "summary", status: "succeeded", finished_at: 1.hour.ago)
      Enliterator::Visit.create!(tendable: widget, facet: "summary", status: "failed", finished_at: Time.current)

      expect(widget.last_tended_at(facet: "summary")).to be_within(1.second).of(newer.finished_at)
      expect(older.finished_at).to be < newer.finished_at
    end
  end
end
