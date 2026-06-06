require "digest"

module Enliterator
  module Adapters
    module Embedder
      # Inert, network-free embedder for tests and offline development.
      #
      # Produces a DETERMINISTIC pseudo-vector of length
      # +Enliterator.configuration.default_embedding_dimensions+ derived from a
      # hash of the input text. Same text in => same vector out, so neighbor math
      # (cosine distance, ordering) is meaningful and repeatable without a network.
      #
      # The vector is L2-normalized so cosine distance behaves well; identical
      # text yields identical vectors (distance 0.0), different text yields stable,
      # well-separated vectors.
      class Null < Base
        def model_id
          "null"
        end

        # @return [Integer] the configured embedding width (default 1536)
        def dimensions
          Enliterator.configuration.default_embedding_dimensions
        end

        # Deterministic pseudo-embedding: seed a tiny PRNG from a SHA256 of the
        # text and fill +dimensions+ floats, then L2-normalize. No randomness,
        # no network.
        # @param text [String]
        # @return [Array<Float>] length == #dimensions
        def embed(text)
          n = dimensions
          seed = Digest::SHA256.hexdigest(text.to_s)[0, 16].to_i(16)
          state = seed.zero? ? 0x9E3779B97F4A7C15 : seed

          vec = Array.new(n) do
            # xorshift64* — small, deterministic, dependency-free PRNG.
            state ^= state >> 12
            state ^= (state << 25) & 0xFFFFFFFFFFFFFFFF
            state ^= state >> 27
            x = (state * 0x2545F4914F6CDD1D) & 0xFFFFFFFFFFFFFFFF
            # Map to [-1.0, 1.0).
            (x.to_f / 0x8000000000000000) - 1.0
          end

          norm = Math.sqrt(vec.sum { |v| v * v })
          return vec if norm.zero?

          vec.map { |v| v / norm }
        end
      end
    end
  end
end
