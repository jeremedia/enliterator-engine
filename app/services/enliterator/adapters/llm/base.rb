module Enliterator
  module Adapters
    module LLM
      # Base interface for LLM tending adapters.
      #
      # An adapter reads a single record's text plus its compounding context
      # (prior claims, recent visits, corpus neighbors) and returns structured
      # claims with an op (ADD/UPDATE/DELETE/NOOP) and an overall confidence.
      #
      # Subclasses MUST implement #model_id and #tend. Prompt construction and the
      # structured-output schema live here so every provider shares them.
      class Base
        # The structured result every #tend implementation returns.
        # - parsed: Hash with "claims" => [...] and "confidence" => Float
        # - raw:    Hash, the provider's raw response (for the Visit row)
        # - tokens: Hash, e.g. {"input" => Int, "output" => Int, "total" => Int}
        Result = Struct.new(:parsed, :raw, :tokens, keyword_init: true)

        # JSON Schema for the forced structured output. Providers that support
        # tool/function calling (Bedrock) bind a single tool to this schema;
        # others can use it for response_format / validation.
        RESPONSE_SCHEMA = {
          "type" => "object",
          "properties" => {
            "claims" => {
              "type" => "array",
              "description" => "The reconciled claims this visit asserts about the record.",
              "items" => {
                "type" => "object",
                "properties" => {
                  "key" => {
                    "type" => "string",
                    "description" => "Stable claim key, e.g. \"summary\" or \"authored_by\"."
                  },
                  "value" => {
                    "description" => "Claim payload: string, array, or object.",
                    "type" => [ "string", "array", "object", "number", "boolean", "null" ]
                  },
                  "confidence" => {
                    "type" => "number",
                    "minimum" => 0.0,
                    "maximum" => 1.0,
                    "description" => "Confidence in this individual claim, 0..1."
                  },
                  "op" => {
                    "type" => "string",
                    "enum" => %w[ADD UPDATE DELETE NOOP],
                    "description" => "Reconciliation op against the current live claim for this key."
                  }
                },
                "required" => %w[key op]
              }
            },
            "confidence" => {
              "type" => "number",
              "minimum" => 0.0,
              "maximum" => 1.0,
              "description" => "Overall confidence in this visit's reconciliation, 0..1."
            }
          },
          "required" => %w[claims confidence]
        }.freeze

        # Name of the single forced tool used by tool-calling providers.
        TOOL_NAME = "emit_claims".freeze

        # @return [String] provider model id (read from config; never hardcoded)
        def model_id
          raise NotImplementedError, "#{self.class} must implement #model_id"
        end

        # Read the record + its compounding context, return a Result.
        # @return [Enliterator::Adapters::LLM::Base::Result]
        def tend(text:, stream:, state:, neighbors:)
          raise NotImplementedError, "#{self.class} must implement #tend"
        end

        private

        # The SYSTEM instruction shared across providers.
        def build_system
          <<~SYSTEM.strip
            You are tending a single data record to confer literacy on it. Your task
            is to read the record's text, its accumulated prior CLAIMS, its RECENT
            VISITS, and its corpus NEIGHBORS, then reconcile what is known into a set
            of provenanced claims.

            Understanding must COMPOUND. Prior claims and visits condition this one:
            confirm what still holds, update what has changed, and only add what is
            genuinely new. Do not discard prior understanding without reason.

            For every claim you assert, choose exactly one reconciliation op:
              - ADD    : a new claim for a key with no current live claim.
              - UPDATE : revise the value of an existing live claim for a key.
              - DELETE : retire an existing live claim (no replacement value needed).
              - NOOP   : the existing live claim still holds; assert it unchanged.

            Return ONLY structured output conforming to the provided schema: an array
            of claims (each with key, value, confidence, op) and an overall
            confidence in [0, 1]. Use stable, reusable keys (e.g. "summary",
            "authored_by"). Be conservative with confidence.
          SYSTEM
        end

        # The USER payload: the record text plus a JSON dump of its compounding
        # context (state) and neighbor summaries.
        def build_user(text:, stream:, state:, neighbors:)
          payload = {
            "stream" => stream.to_s,
            "record_text" => text.to_s,
            "state" => state,
            "neighbors" => summarize_neighbors(neighbors)
          }

          <<~USER.strip
            Tend this record along the "#{stream}" stream.

            CONTEXT (JSON — prior claims, recent visits, facets, and corpus neighbors):
            #{JSON.pretty_generate(payload)}

            Reconcile the record's understanding and emit claims via the structured
            output. Read the prior CLAIMS and VISITS in state before deciding each op.
          USER
        end

        # Reduce neighbor records/embeddings to a compact, JSON-safe shape.
        def summarize_neighbors(neighbors)
          Array(neighbors).map do |n|
            if n.respond_to?(:enliterator_text)
              { "type" => n.class.name, "id" => n.id.to_s, "text" => n.enliterator_text.to_s }
            elsif n.is_a?(Enliterator::Embedding)
              { "type" => n.embeddable_type, "id" => n.embeddable_id.to_s, "kind" => n.kind }
            else
              { "value" => n.to_s }
            end
          end
        end
      end
    end
  end
end
