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

        # Accepts +contract:+ (v0.3) and +required:+ (v0.5) for signature parity with
        # the contract-aware adapters; the inert adapter ignores both and proposes nothing.
        def tend(text:, stream:, state:, neighbors:, contract: nil, required: nil)
          Result.new(
            parsed: { "claims" => [], "confidence" => 0.0 },
            raw:    { "adapter" => "null" },
            tokens: {}
          )
        end

        # The inert conversational response (v0.6). Returns a deterministic canned
        # answer so CI (no gateway key) exercises the chat + SSE path. When streaming,
        # yields it token-by-token (whitespace preserved) so the streaming code path
        # is covered. Does NOT raise — conversation writes no rows, so the v0.5
        # phantom-Visit hazard doesn't apply here; the caller surfaces the degraded
        # state instead.
        CANNED_REPLY =
          "The Null adapter is active: no language model was called. Configure a " \
          "gateway tier (ENLITERATOR_LLM_KEY) to converse with the enliteration.".freeze

        def converse(messages:, tags: [], stream: false, &block)
          CANNED_REPLY.split(/(\s+)/).each { |tok| block.call(tok) } if stream && block
          CANNED_REPLY
        end
      end
    end
  end
end
