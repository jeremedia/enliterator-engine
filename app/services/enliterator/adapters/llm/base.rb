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
        #
        # +contract+ (v0.3) is an optional `{key_sym => "description"}` hash naming
        # the allowed claim keys for this stream. When present, subclasses thread
        # `schema_for(contract)` into their structured-output schema (claim `key`
        # becomes an enum + an optional top-level `suggestions` array) and
        # `system_for(contract)` into the system message. When nil/absent, behavior
        # is byte-identical to v0.2 (open `key` string, default RESPONSE_SCHEMA, no
        # suggestions emphasis).
        #
        # @return [Enliterator::Adapters::LLM::Base::Result]
        def tend(text:, stream:, state:, neighbors:, contract: nil, required: nil)
          raise NotImplementedError, "#{self.class} must implement #tend"
        end

        # Free-form conversational completion (v0.6) — the conversational surface of
        # an enliteration. UNLIKE #tend (forced structured tool output), this answers
        # in natural language grounded in the +messages+ the caller assembles (a
        # collection self-portrait + retrieved records' claims). When +stream+ is true
        # AND a block is given, the block is yielded incremental text deltas as they
        # arrive; either way the full concatenated answer string is returned. +tags+
        # ride along as LiteLLM spend attribution, exactly as in #tend.
        #
        # @return [String] the full answer text.
        def converse(messages:, tags: [], stream: false, &block)
          raise NotImplementedError, "#{self.class} must implement #converse"
        end

        # The structured-output schema for a call. With no contract this is the
        # default RESPONSE_SCHEMA constant ITSELF (identity preserved, so the v0.2
        # adapter specs comparing against RESPONSE_SCHEMA stay green). With a
        # contract it is a per-call variant where claim `key` is an enum over the
        # allowed keys AND an optional top-level `suggestions` array is added.
        #
        # @param contract [Hash, nil] `{key => description}` or nil.
        # @return [Hash] JSON Schema.
        def schema_for(contract)
          keys = allowed_keys_from(contract)
          return RESPONSE_SCHEMA if keys.nil? || keys.empty?

          schema = deep_dup(RESPONSE_SCHEMA)
          schema["properties"]["claims"]["items"]["properties"]["key"] = {
            "type" => "string",
            "enum" => keys,
            "description" => "Stable claim key. Use ONLY one of the allowed keys for this stream."
          }
          schema["properties"]["suggestions"] = SUGGESTIONS_SCHEMA_PROPERTY
          # "suggestions" stays OPTIONAL — do not add it to "required".
          schema
        end

        # The system instruction for a call. With no contract this is the exact
        # v0.2 `build_system` text (byte-identical). With a contract it appends a
        # controlled-vocabulary block listing the allowed keys + descriptions and
        # instructing the model to use ONLY those keys and route gaps to
        # `suggestions` rather than inventing a key.
        #
        # @param contract [Hash, nil] `{key => description}` or nil.
        # @return [String]
        def system_for(contract, required: nil)
          base = build_system
          keys = allowed_keys_from(contract)
          return base if keys.nil? || keys.empty?

          base + "\n\n" + contract_system_block(contract, required: required)
        end

        private

        # Optional top-level "suggestions" schema fragment, attached only when a
        # contract is present. Each entry is the model's sanctioned channel to
        # propose a NEW claim key it could not express within the allowed set.
        SUGGESTIONS_SCHEMA_PROPERTY = {
          "type" => "array",
          "description" =>
            "Sanctioned channel for proposing NEW claim keys. If you observe " \
            "something worth asserting that no allowed key covers, DO NOT invent " \
            "a key on a claim — add an entry here instead. Optional; omit when the " \
            "allowed keys suffice.",
          "items" => {
            "type" => "object",
            "properties" => {
              "proposed_key" => {
                "type" => "string",
                "description" => "The new claim key you would add to the controlled vocabulary."
              },
              "rationale" => {
                "type" => "string",
                "description" => "Why this key is needed and not covered by an allowed key."
              },
              "example_value" => {
                "description" => "An example value this key would carry for this record.",
                "type" => [ "string", "array", "object", "number", "boolean", "null" ]
              }
            },
            "required" => %w[proposed_key rationale]
          }
        }.freeze

        # Normalize a contract hash into a sorted list of allowed key STRINGS,
        # or nil when there is no usable contract.
        def allowed_keys_from(contract)
          return nil if contract.nil?
          return nil unless contract.is_a?(Hash)
          keys = contract.keys.map(&:to_s).reject(&:empty?)
          keys.empty? ? nil : keys
        end

        # The controlled-vocabulary instruction appended to the system message
        # when a contract is present. When +required+ names keys, a REQUIRED block
        # is appended emphasizing they must be asserted (instruction-level — a JSON
        # schema cannot force array CONTENTS, only shape). With no required keys the
        # text is byte-identical to v0.3/v0.4.
        def contract_system_block(contract, required: nil)
          lines = contract.map { |k, desc| "  - #{k}: #{desc}" }.join("\n")
          block = <<~CONTRACT.strip
            CONTROLLED VOCABULARY — this stream has a fixed set of allowed claim keys.
            Use ONLY these keys for the `key` of every claim:

            #{lines}

            If you observe something worth asserting that NONE of these keys covers,
            DO NOT invent a new key on a claim. Instead add it to the optional
            top-level `suggestions` array as {proposed_key, rationale, example_value}.
            Never put an off-list key on a claim.
          CONTRACT

          req = Array(required).map(&:to_s).reject(&:empty?)
          return block if req.empty?

          block + "\n\n" + <<~REQUIRED.strip
            REQUIRED keys — you MUST assert a claim for EACH of: #{req.join(', ')}.
            These facts are present in the record; find and assert them. Only if a
            required key is genuinely absent from the record, assert it with an empty
            value and low confidence rather than omitting it.
          REQUIRED
        end

        # Recursively duplicate a (frozen) nested Hash/Array structure so a
        # per-call schema variant can be mutated without touching RESPONSE_SCHEMA.
        def deep_dup(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
          when Array
            obj.map { |v| deep_dup(v) }
          else
            obj
          end
        end

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

        # Reduce neighbor records/embeddings to a compact, JSON-safe shape. The text
        # is truncated to a short identifying snippet (title + opening) so the model
        # can reference a neighbor without bloating the prompt with full abstracts.
        NEIGHBOR_SNIPPET_CHARS = 280

        def summarize_neighbors(neighbors)
          Array(neighbors).map do |n|
            if n.respond_to?(:enliterator_text)
              { "type" => n.class.name, "id" => n.id.to_s,
                "text" => n.enliterator_text.to_s[0, NEIGHBOR_SNIPPET_CHARS] }
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
