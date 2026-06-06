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
            },
            # OPTIONAL self-escalation flag (v0.2). A model may set this true to ask
            # that a more capable tier review this record — e.g. the input is
            # ambiguous, conflicting, or beyond this tier's competence — even when
            # its numeric confidence is otherwise acceptable. NOT required, so older
            # adapters and prompts that never emit it stay valid against this schema.
            "escalate" => {
              "type" => "boolean",
              "description" => "Set true to request that a senior tier review this record."
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
        #
        # When escalation hands a record up the ladder, the Visitor puts the junior
        # tier's proposed claims into state under "proposed_by_lower_tier". We pull
        # that out and present it as an explicit REVIEW section so a senior tier
        # treats the junior's draft as a thing to confirm/correct, not as buried
        # context. Tolerated optionally: when absent, the prompt is unchanged.
        def build_user(text:, stream:, state:, neighbors:)
          state_hash = state.is_a?(Hash) ? state : {}
          proposed   = state_hash["proposed_by_lower_tier"] || state_hash[:proposed_by_lower_tier]

          payload = {
            "stream" => stream.to_s,
            "record_text" => text.to_s,
            "state" => state,
            "neighbors" => summarize_neighbors(neighbors)
          }

          review_block =
            if proposed
              <<~REVIEW.strip + "\n\n"

                REVIEW — DRAFT CLAIMS PROPOSED BY A LOWER TIER:
                A junior tier already tended this record and proposed the claims below.
                You are the senior reviewer. Confirm what is correct, correct what is
                wrong, and add anything it missed — your reconciliation is the one that
                will be written. Do not simply restate the draft without judgment.

                #{JSON.pretty_generate("proposed_by_lower_tier" => proposed)}
              REVIEW
            else
              ""
            end

          <<~USER.strip
            Tend this record along the "#{stream}" stream.

            #{review_block}CONTEXT (JSON — prior claims, recent visits, facets, and corpus neighbors):
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
