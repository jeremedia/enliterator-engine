module Enliterator
  module Adapters
    module Embedder
      # Interface for embedder adapters.
      #
      # An embedder turns a record's text representation into a fixed-length
      # vector that lands in the `enliterator_embeddings.embedding` column and
      # powers neighbor search. Concrete adapters (Null/OpenAI) implement the
      # three methods below; the engine only ever calls through this contract.
      #
      #   adapter.model_id    # => "text-embedding-3-small"
      #   adapter.dimensions  # => 1536
      #   adapter.embed(text) # => Array<Float> of length #dimensions
      class Base
        # Embedder model id that produced the vector. Stored on Embedding#model
        # so a host can tell which model wrote a given row (and re-embed on change).
        def model_id
          raise NotImplementedError, "#{self.class}#model_id must be implemented"
        end

        # Turn +text+ into a vector.
        # @param text [String]
        # @return [Array<Float>] length must equal #dimensions
        def embed(text)
          raise NotImplementedError, "#{self.class}#embed must be implemented"
        end

        # Width of the produced vector. Must match the configured
        # embeddings column width (default 1536).
        # @return [Integer]
        def dimensions
          raise NotImplementedError, "#{self.class}#dimensions must be implemented"
        end
      end
    end
  end
end
