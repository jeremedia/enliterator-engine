module Enliterator
  module Adapters
    module LLM
      # Raised when a gateway/bedrock adapter receives a non-empty claims string
      # that cannot be parsed into usable claim hashes — i.e. the model returned
      # a stringified JSON array that is malformed (e.g. single-escaped embedded
      # quotes). Raising surfaces the failure as a visible, retriable Visit error
      # rather than silently dropping all claims and opening a phantom lacuna
      # (rule 3: no silent failures).
      class ResponseFormatError < StandardError; end

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
        # +contract+ (v0.3) is an optional `{term_sym => "description"}` hash naming
        # the allowed terms for this facet. When present, subclasses thread
        # `schema_for(contract)` into their structured-output schema (claim `key`
        # becomes an enum + an optional top-level `suggestions` array) and
        # `system_for(contract)` into the system message. When nil/absent, behavior
        # is byte-identical to v0.2 (open `key` string, default RESPONSE_SCHEMA, no
        # suggestions emphasis).
        #
        # @return [Enliterator::Adapters::LLM::Base::Result]
        def tend(text:, facet:, state:, neighbors:, contract: nil, required: nil, candidates: nil)
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

        # General forced-tool structured call (v0.8) — the considerer's substrate.
        # Binds a single tool named +tool_name+ to the given JSON +schema+ and
        # compels it, returning the parsed tool-call arguments as a Hash. Unlike
        # #tend (whose schema is fixed to emit_claims) this takes an arbitrary
        # schema, so any caller can get structured output.
        #
        # @return [Hash] the parsed arguments (shape == +schema+).
        def decide(messages:, schema:, tool_name:, tags: [])
          raise NotImplementedError, "#{self.class} must implement #decide"
        end

        # v0.28: optional-multi-tool completion. Offers +tools+ with tool_choice
        # "auto"; returns a ToolTurn (text OR tool_calls). Only the Gateway adapter
        # implements it — Null/Bedrock inherit this raise so a misconfigured
        # federation fails loudly, never silently.
        def converse_with_tools(messages:, tools:, tags: [], stream: false, &block)
          raise NotImplementedError, "#{self.class} does not implement converse_with_tools"
        end

        # The structured-output schema for a call. With no contract this is the
        # default RESPONSE_SCHEMA constant ITSELF (identity preserved, so the v0.2
        # adapter specs comparing against RESPONSE_SCHEMA stay green). With a
        # contract it is a per-call variant where claim `key` is an enum over the
        # allowed keys AND an optional top-level `suggestions` array is added.
        #
        # @param contract [Hash, nil] `{key => description}` or nil.
        # @param required [Array, nil] the facet's REQUIRED terms (v0.46.1) — when
        #   present AND config.record_lacunae is on, an optional top-level `absences`
        #   array is added so the model can diagnose a required term it cannot fill.
        # @return [Hash] JSON Schema.
        def schema_for(contract, required: nil)
          keys = allowed_terms_from(contract)
          return RESPONSE_SCHEMA if keys.nil? || keys.empty?

          schema = deep_dup(RESPONSE_SCHEMA)
          schema["properties"]["claims"]["items"]["properties"]["key"] = {
            "type" => "string",
            "enum" => keys,
            "description" => "Stable term. Use ONLY one of the allowed terms for this facet."
          }
          schema["properties"]["suggestions"] = SUGGESTIONS_SCHEMA_PROPERTY
          # "suggestions" stays OPTIONAL — do not add it to "required".

          # v0.46.1: the absences (diagnosis) channel. Added ONLY when this facet has
          # REQUIRED terms AND lacuna-recording is on — so a host with required terms
          # but the flag off keeps a byte-identical schema (the `&& record_lacunae`
          # conjunct is load-bearing for rule 1). Stays OPTIONAL.
          if Array(required).map(&:to_s).reject(&:empty?).any? && Enliterator.configuration.record_lacunae
            schema["properties"]["absences"] = ABSENCES_SCHEMA_PROPERTY
          end
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
        def system_for(contract, required: nil, candidates: nil)
          base = build_system
          keys = allowed_terms_from(contract)
          return base if keys.nil? || keys.empty?

          out = base + "\n\n" + contract_system_block(contract, required: required)
          out += "\n\n" + candidates_block(candidates) if candidates&.any?
          out
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

        # Optional top-level "absences" schema fragment (v0.46.1), attached by
        # schema_for ONLY when a contract has REQUIRED terms and config.record_lacunae
        # is on. Each entry is the model's sanctioned channel to DIAGNOSE a required
        # term it could not fill, instead of asserting a contentless empty claim. The
        # diagnosis is a hint (why the fact is missing), not a verdict; the engine's
        # no-info default "undiagnosed" is NEVER offered here — the model picks one of
        # the three substantive causes (Lacuna::DIAGNOSES minus undiagnosed) or abstains.
        ABSENCES_SCHEMA_PROPERTY = {
          "type" => "array",
          "description" =>
            "Sanctioned channel for diagnosing UNFILLABLE required terms. For any " \
            "REQUIRED term you cannot assert from this record, DO NOT emit an empty " \
            "claim — add an entry here instead. Optional; omit when every required " \
            "term is satisfied.",
          "items" => {
            "type" => "object",
            "properties" => {
              "term" => {
                "type" => "string",
                "description" => "The REQUIRED term you could not fill."
              },
              "diagnosis" => {
                "type" => "string",
                "enum" => %w[defective_surrogate silent not_identified],
                "description" =>
                  "Why the term is unfillable: defective_surrogate = the fact is in " \
                  "the item but our extraction lost it; silent = the item omits it " \
                  "(an external authority may know); not_identified = genuinely " \
                  "unrecoverable."
              },
              "note" => {
                "type" => "string",
                "description" => "Optional brief evidence for the diagnosis."
              }
            },
            "required" => %w[term diagnosis]
          }
        }.freeze

        # Normalize a contract hash into a sorted list of allowed key STRINGS,
        # or nil when there is no usable contract.
        def allowed_terms_from(contract)
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
            CONTROLLED VOCABULARY — this facet has a fixed set of allowed terms.
            Use ONLY these terms for the `key` of every claim:

            #{lines}

            If you observe something worth asserting that NONE of these terms covers,
            DO NOT invent a new term on a claim. Instead add it to the optional
            top-level `suggestions` array as {proposed_key, rationale, example_value}.
            Never put an off-list term on a claim.
          CONTRACT

          req = Array(required).map(&:to_s).reject(&:empty?)
          return block if req.empty?

          # v0.46.1: when lacuna-recording is on, the closing instruction is SWAPPED
          # (not appended) — route an unfillable required term to the `absences` array
          # with a diagnosis, instead of asserting an empty claim. The two instructions
          # are contradictory, so only one may ship. Flag OFF → the else branch is
          # byte-identical to the v0.5/v0.46 text (rule 1).
          if Enliterator.configuration.record_lacunae
            block + "\n\n" + <<~REQUIRED.strip
              REQUIRED terms — you MUST assert a claim for EACH of: #{req.join(', ')}.
              These facts are present in the record; find and assert them. If a required
              term is genuinely absent from the record, DO NOT assert an empty claim for
              it — instead add an entry to the top-level `absences` array as {term,
              diagnosis, note}, choosing diagnosis from: defective_surrogate (the fact is
              in the item but our extraction lost it), silent (the item omits it; an
              external authority may know), or not_identified (genuinely unrecoverable).
              Abstain rather than guess the diagnosis.
            REQUIRED
          else
            block + "\n\n" + <<~REQUIRED.strip
              REQUIRED terms — you MUST assert a claim for EACH of: #{req.join(', ')}.
              These facts are present in the record; find and assert them. Only if a
              required key is genuinely absent from the record, assert it with an empty
              value and low confidence rather than omitting it.
            REQUIRED
          end
        end

        # Stage 1 — the CANDIDATE-vocabulary block, appended by system_for as a SIBLING
        # AFTER the contract block (gated on candidates&.any?). Renders the warrant-
        # ranked candidates other readers have proposed + the three-tier affirm
        # instruction + the value-vs-key discipline. NOTE the deliberate override:
        # affirming re-emits an EXISTING candidate key into `suggestions`, contradicting
        # that array's general "propose NEW keys" framing — so the override is stated
        # HERE, in the gated prompt, NOT by editing SUGGESTIONS_SCHEMA_PROPERTY (which
        # schema_for adds unconditionally; changing it would alter the schema for every
        # contract facet even when this is off, breaking byte-identity).
        def candidates_block(candidates)
          lines = candidates.map { |c|
            key = c[:proposed_key] || c["proposed_key"]
            cnt = (c[:count] || c["count"]).to_i
            rat = c[:sample_rationale] || c["sample_rationale"]
            "  - #{key} (proposed by #{cnt} record#{'s' unless cnt == 1}): #{rat}"
          }.join("\n")
          <<~CANDIDATES.strip
            CANDIDATE VOCABULARY — terms OTHER readers have already proposed for this
            facet but a curator has not yet ratified. They carry literary warrant; help
            the vocabulary CONVERGE rather than fragment:

            #{lines}

            If your observation matches one of these candidates, AFFIRM it: re-propose it
            in the `suggestions` array using its EXACT proposed_key. This is intended even
            though the key already exists — re-emitting it is HOW warrant accrues, and it
            overrides the array's general "propose a NEW key" guidance for these
            candidates. Propose a genuinely new key ONLY when neither an allowed term nor
            any candidate above fits.

            A concept specific to THIS record — one a reader would look up here, not a
            dimension many records share — belongs as a VALUE under an existing
            value-bearing key (e.g. index terms), NOT as a new proposed key.
          CANDIDATES
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
        def build_user(text:, facet:, state:, neighbors:)
          state_hash = state.is_a?(Hash) ? state : {}
          proposed   = state_hash["proposed_by_lower_tier"] || state_hash[:proposed_by_lower_tier]

          payload = {
            "facet" => facet.to_s,
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
            Tend this record along the "#{facet}" facet.

            #{review_block}CONTEXT (JSON — prior claims, recent visits, measures, and corpus neighbors):
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
