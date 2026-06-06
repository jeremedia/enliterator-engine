module Enliterator
  module Adapters
    module LLM
      # Inert LLM adapter. Used by default when no llm_adapter is configured.
      #
      # Safe for tests and safe to leave in place in production: it performs NO
      # network I/O and proposes no claims. Every #tend returns an empty
      # reconciliation, so a Visit still records cleanly (status succeeded, zero
      # claims changed) without depending on any provider gem or credentials.
      class Null < Base
        def model_id
          "null"
        end

        def tend(text:, stream:, state:, neighbors:)
          Result.new(
            parsed: { "claims" => [], "confidence" => 0.0 },
            raw:    { "adapter" => "null" },
            tokens: {}
          )
        end
      end
    end
  end
end
