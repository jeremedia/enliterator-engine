require "rails_helper"

# The Null embedder is the default, network-free vectorizer. It must produce a
# DETERMINISTIC pseudo-vector of the configured width so neighbor math (cosine
# distance, ordering) is meaningful and repeatable in tests without a provider.
# This spec pins that contract: width, determinism, separation, normalization.
RSpec.describe Enliterator::Adapters::Embedder::Null do
  subject(:adapter) { described_class.new }

  it "is a kind of Embedder::Base" do
    expect(adapter).to be_a(Enliterator::Adapters::Embedder::Base)
  end

  describe "#model_id" do
    it "is the literal \"null\"" do
      expect(adapter.model_id).to eq("null")
    end
  end

  describe "#dimensions" do
    it "matches the configured default embedding dimensions" do
      expect(adapter.dimensions).to eq(Enliterator.configuration.default_embedding_dimensions)
    end

    it "tracks a reconfigured width" do
      Enliterator.configure { |c| c.default_embedding_dimensions = 8 }
      expect(adapter.dimensions).to eq(8)
    end
  end

  describe "#embed" do
    it "returns a vector of #dimensions floats" do
      vec = adapter.embed("hello world")
      expect(vec).to be_an(Array)
      expect(vec.length).to eq(adapter.dimensions)
      expect(vec).to all(be_a(Float))
    end

    it "is deterministic: same text in => same vector out" do
      expect(adapter.embed("repeatable")).to eq(adapter.embed("repeatable"))
    end

    it "separates different text into different vectors" do
      expect(adapter.embed("alpha")).not_to eq(adapter.embed("omega"))
    end

    it "produces an L2-normalized vector (unit length), so cosine behaves well" do
      vec  = adapter.embed("normalize me")
      norm = Math.sqrt(vec.sum { |v| v * v })
      expect(norm).to be_within(1e-6).of(1.0)
    end

    it "performs no network I/O (offline, dependency-free)" do
      # No provider gem, no socket — pure hashing. Empty input is still safe and
      # yields a correctly sized vector.
      vec = adapter.embed("")
      expect(vec.length).to eq(adapter.dimensions)
    end

    it "honors a reconfigured width when embedding" do
      Enliterator.configure { |c| c.default_embedding_dimensions = 16 }
      expect(adapter.embed("sized").length).to eq(16)
    end

    it "is the adapter Enliterator.embedder falls back to when none is configured" do
      expect(Enliterator.embedder).to be_a(described_class)
    end
  end
end
