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
      visit = Enliterator::Visit.create!(tendable: widget, stream: "summary", status: "pending")
      expect(widget.enliterator_visits).to include(visit)
      expect(visit.tendable).to eq(widget)
    end

    it "has_many enliterator_claims as a polymorphic tendable" do
      claim = Enliterator::Claim.create!(tendable: widget, key: "summary", value: "v")
      expect(widget.enliterator_claims).to include(claim)
      expect(claim.tendable).to eq(widget)
    end

    it "has_many enliterator_facets as a polymorphic tendable" do
      facet = Enliterator::Facet.create!(tendable: widget, name: "completeness", score: 0.0)
      expect(widget.enliterator_facets).to include(facet)
      expect(facet.tendable).to eq(widget)
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
      Enliterator::Visit.create!(tendable: widget, stream: "summary", status: "pending")
      Enliterator::Claim.create!(tendable: widget, key: "summary", value: "v")
      Enliterator::Facet.create!(tendable: widget, name: "completeness", score: 0.0)
      Enliterator::Embedding.create!(
        embeddable: widget,
        kind:       "primary",
        embedding:  Enliterator::Adapters::Embedder::Null.new.embed("Acme")
      )

      expect { widget.destroy }
        .to change(Enliterator::Visit, :count).by(-1)
        .and change(Enliterator::Claim, :count).by(-1)
        .and change(Enliterator::Facet, :count).by(-1)
        .and change(Enliterator::Embedding, :count).by(-1)
    end
  end

  describe "#enliterator_text" do
    it "uses the host's to_enliterator_text override" do
      expect(widget.enliterator_text).to eq("Acme\nA widget.")
    end
  end

  describe "#literacy_state" do
    it "returns the compounding-context shape: claims, recent_visits, facets" do
      state = widget.literacy_state(stream: "summary")

      expect(state).to be_a(Hash)
      expect(state.keys).to contain_exactly(:claims, :recent_visits, :facets)
      expect(state[:claims]).to eq([])
      expect(state[:recent_visits]).to eq([])
      expect(state[:facets]).to eq({})
    end

    it "includes only LIVE claims, projected via to_state" do
      live       = Enliterator::Claim.create!(tendable: widget, key: "summary", value: "kept", status: "draft")
      superseded = Enliterator::Claim.create!(tendable: widget, key: "old", value: "gone", status: "superseded")

      state = widget.literacy_state(stream: "summary")

      keys = state[:claims].map { |c| c[:key] }
      expect(keys).to include(live.key)
      expect(keys).not_to include(superseded.key)
      # to_state projection, not raw records.
      expect(state[:claims].first).to include(:key, :value, :confidence, :status, :locked)
    end

    it "includes recent visits for the given stream, projected via to_state" do
      visit = Enliterator::Visit.create!(
        tendable:       widget,
        stream:         "summary",
        status:         "succeeded",
        confidence:     0.7,
        reconciliation: { "added" => [ "summary" ] }
      )
      Enliterator::Visit.create!(tendable: widget, stream: "other", status: "succeeded")

      state = widget.literacy_state(stream: "summary")

      expect(state[:recent_visits].size).to eq(1)
      projected = state[:recent_visits].first
      expect(projected[:stream]).to eq(visit.stream)
      expect(projected).to include(:stream, :confidence, :summary, :at)
    end

    it "maps facets by name to score" do
      Enliterator::Facet.create!(tendable: widget, name: "completeness", score: 0.5)

      state = widget.literacy_state(stream: "summary")

      expect(state[:facets]).to eq("completeness" => 0.5)
    end
  end

  describe "#last_tended_at" do
    it "returns nil when there are no succeeded visits" do
      expect(widget.last_tended_at).to be_nil
    end

    it "returns the newest succeeded visit's finished_at, scoped by stream" do
      older = Enliterator::Visit.create!(tendable: widget, stream: "summary", status: "succeeded", finished_at: 2.days.ago)
      newer = Enliterator::Visit.create!(tendable: widget, stream: "summary", status: "succeeded", finished_at: 1.hour.ago)
      Enliterator::Visit.create!(tendable: widget, stream: "summary", status: "failed", finished_at: Time.current)

      expect(widget.last_tended_at(stream: "summary")).to be_within(1.second).of(newer.finished_at)
      expect(older.finished_at).to be < newer.finished_at
    end
  end
end
