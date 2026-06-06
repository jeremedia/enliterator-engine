require "rails_helper"

# Embeddings are named vectors per record. nearest_to is the corpus-context lookup
# the Visitor uses to find neighbors. This spec proves, with the network-free Null
# embedder, that nearest_to returns rows ordered by cosine distance (nearest first),
# each carrying the neighbor gem's neighbor_distance attribute.
RSpec.describe Enliterator::Embedding do
  let(:embedder) { Enliterator::Adapters::Embedder::Null.new }

  # Persist a "primary" embedding for `text` on a fresh Widget host.
  def embed!(text, kind: "primary")
    widget = Widget.create!(title: text, body: text)
    described_class.create!(
      embeddable: widget,
      kind:       kind,
      embedding:  embedder.embed(text),
      dimensions: embedder.dimensions,
      model:      embedder.model_id
    )
  end

  describe ".nearest_to" do
    it "returns embeddings ordered by ascending cosine distance" do
      # Three distinct vectors. The Null embedder is deterministic, so the query
      # vector below (re-embedding "alpha") is exactly the "alpha" row's vector —
      # giving it distance ~0 and forcing a clear, stable ordering.
      a = embed!("alpha")
      b = embed!("bravo")
      c = embed!("charlie")

      query = embedder.embed("alpha")
      results = described_class.nearest_to(query, kind: "primary", limit: 3)

      # All three rows come back, and they are sorted nearest-first.
      expect(results.map(&:id)).to contain_exactly(a.id, b.id, c.id)
      distances = results.map(&:neighbor_distance)
      expect(distances).to eq(distances.sort)

      # The exact match (alpha) is the nearest, at ~0 distance.
      expect(results.first.id).to eq(a.id)
      expect(results.first.neighbor_distance).to be_within(1e-6).of(0.0)
    end

    it "honors the limit" do
      embed!("alpha")
      embed!("bravo")
      embed!("charlie")

      query   = embedder.embed("alpha")
      results = described_class.nearest_to(query, kind: "primary", limit: 2)

      expect(results.size).to eq(2)
    end

    it "scopes by kind" do
      primary = embed!("alpha", kind: "primary")
      embed!("alpha-fulltext", kind: "full_text")

      query   = embedder.embed("alpha")
      results = described_class.nearest_to(query, kind: "primary", limit: 5)

      expect(results.map(&:kind).uniq).to eq([ "primary" ])
      expect(results.map(&:id)).to include(primary.id)
    end

    it "ranks a near-duplicate ahead of an unrelated vector" do
      target  = embed!("the quick brown fox")
      similar = embed!("the quick brown fox jumps")
      embed!("totally unrelated content here")

      results = described_class.nearest_to(embedder.embed("the quick brown fox"), kind: "primary", limit: 3)

      # The exact match leads; its near-duplicate outranks the unrelated row.
      expect(results.first.id).to eq(target.id)
      ordered_ids = results.map(&:id)
      expect(ordered_ids.index(similar.id)).to be < ordered_ids.index(ordered_ids.last)
    end
  end
end
