module Enliterator
  class Audit < ApplicationRecord
    # v0.18 — the LLM examiner: renders one verdict on one claim against its
    # source, via the same forced-tool `decide` plumbing the considerer, judge,
    # and conservator use. BLIND to the claim's tier, confidence, attribution,
    # status, and sibling claims — it sees the facet, the term's controlled
    # meaning, the claim, and the source. It reads the SAME full
    # `enliterator_text(facet:)` the tend read (generous ceiling; truncation
    # stamped) — a snippet-bound examiner yields false "unsupported" for
    # deep-grounded claims, the inverse of the failure this instrument exists
    # to catch.
    #
    # Honesty (SPEC v0.18): the examiner shares the tender's worldview —
    # correlated errors; the HUMAN anchor is its only calibration. Verdicts
    # are rendered against the CURRENT source (digest stamped so the Review
    # surface can flag drift).
    class Examiner
      TOOL_NAME = "render_verdict".freeze

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "verdict" => { "type" => "string", "enum" => Enliterator::Audit::VERDICTS,
                         "description" => "supported / unsupported / contradicted / unverifiable — per the definitions given" },
          "rationale" => { "type" => "string", "description" => "one or two sentences citing the source" },
          "corrected_value" => { "type" => "string",
                                 "description" => "ONLY when contradicted: the value the source actually supports" },
          "confidence" => { "type" => "number", "minimum" => 0.0, "maximum" => 1.0 }
        },
        "required" => %w[verdict rationale confidence]
      }.freeze

      def initialize(llm: nil, tier: nil)
        @llm  = llm
        @tier = tier
      end

      # Examine one claim. Returns the Audit row, or a Symbol naming why not:
      # :blank_source (nothing to verify against — also a condition signal),
      # :unavailable (Null adapter — the CALLER must make this visible).
      def examine!(claim, heartbeat: nil)
        record = claim.tendable
        facet  = claim.visit&.facet
        return :blank_source if record.nil? || facet.nil?

        full = record.enliterator_text(facet: facet).to_s
        return :blank_source if full.strip.empty?

        adapter = resolve_llm
        return :unavailable if adapter.is_a?(Enliterator::Adapters::LLM::Null)

        ceiling   = Enliterator.configuration.audit_source_chars.to_i
        truncated = full.length > ceiling
        source    = truncated ? full[0, ceiling] : full

        rendered = verdict_for(facet: facet, key: claim.key, value: claim.value,
                               context: claim.context, source: source,
                               truncated: truncated)
        return rendered if rendered.is_a?(Symbol)

        Enliterator::Audit.create!(
          claim:            claim,
          verdict:          rendered[:verdict],
          rationale:        rendered[:rationale],
          corrected_value:  rendered[:corrected_value],
          confidence:       rendered[:confidence],
          source:           "examiner",
          # v0.68: "<alias>:<resolved backend>". The examiner is the collection's
          # measuring instrument, and `Audit.accuracy` never ages out — so a
          # silent backend swap behind a stable alias would mix two examiners into
          # one number with nothing in the record to separate them.
          auditor:          "#{rendered[:tier]}:#{rendered[:model]}",
          heartbeat:        heartbeat,
          source_digest:    Digest::MD5.hexdigest(full),
          source_chars:     full.length,
          source_truncated: truncated
        )
      end

      # v0.70 — the INSTRUMENT, separated from the filing cabinet.
      #
      # Renders one grounded verdict on one key/value against one source and
      # returns it. Persists NOTHING. `examine!` is this plus an Audit row; a
      # bake-off is this over claims that were never written, so a candidate
      # reader can be measured without touching the live claim store.
      #
      # Blind by construction: the caller passes a key, a value, and a source —
      # there is no parameter through which the model that PRODUCED the value
      # could reach the examiner, which is what makes a comparison fair.
      #
      # v0.72.5 — `truncated:` states whether `source` is a partial excerpt of
      # the document. It matters ONLY for a blank-valued claim (a claim of
      # ABSENCE): a positive claim needs its evidence to appear somewhere, but
      # an absence claim asserts something about the WHOLE document — a partial
      # excerpt can refute it (the source names a value) and can never confirm
      # it. nil means UNKNOWN completeness and is treated as not-known-complete:
      # a caller that doesn't vouch the source is whole cannot mint
      # absence-confirmations. Non-blank calls ignore it entirely (the prompt
      # is byte-identical to v0.70 — golden-pinned).
      #
      # Returns a Hash, or :unavailable / :blank_source.
      def verdict_for(facet:, key:, value:, source:, context: nil, truncated: nil)
        return :blank_source if source.to_s.strip.empty?

        adapter = resolve_llm
        return :unavailable if adapter.is_a?(Enliterator::Adapters::LLM::Null)

        absence = Enliterator::Claim.blank_value?(value)

        # v0.68: ask the adapter to report which backend actually answered. The
        # kwarg is probed rather than assumed so third-party and stub adapters
        # with the pre-v0.68 signature keep working (the engine's established
        # optional-kwarg idiom); those simply leave meta empty and we fall back
        # to the alias below.
        meta = {}
        decide_args = {
          messages:  messages_for(facet: facet, key: key, value: value, context: context,
                                  source: source, absence: absence, truncated: truncated),
          schema:    SCHEMA,
          tool_name: TOOL_NAME,
          tags:      [ "enliterator", "audit-examiner" ]
        }
        decide_args[:meta] = meta if adapter.method(:decide).parameters.any? { |_t, n| n == :meta }
        result = adapter.decide(**decide_args)

        verdict = (result["verdict"] || result[:verdict]).to_s
        verdict = "unverifiable" unless Enliterator::Audit::VERDICTS.include?(verdict)
        verdict = coerce_absence_verdict(verdict, truncated: truncated, key: key) if absence

        {
          verdict:         verdict,
          rationale:       (result["rationale"] || result[:rationale]).to_s,
          corrected_value: (result["corrected_value"] || result[:corrected_value]).presence || {},
          confidence:      (result["confidence"] || result[:confidence]).to_f,
          tier:            effective_tier,
          model:           meta[:model].presence || (adapter.respond_to?(:model_id) ? adapter.model_id : "unknown")
        }
      end

      private

      def resolve_llm
        return @llm if @llm
        Enliterator.llm(tier: effective_tier)
      end

      def effective_tier
        @tier || Enliterator.configuration.audit_tier ||
          Enliterator.staffing.ladder.last || "quality"
      end

      # v0.72.5: a blank-valued claim gets the ABSENCE system block INSTEAD of
      # the standard one — a SWAP, not an append (the two sets of verdict
      # definitions contradict on what `supported` means, and shipping both
      # degrades the verdict; the v0.46.1 lesson). Non-blank calls are
      # byte-identical to v0.70 (golden-pinned).
      def messages_for(facet:, key:, value:, context:, source:, absence: false, truncated: nil)
        meaning = Enliterator::Vocabulary.for(facet, context: context)&.dig(key)
        system  = absence ? absence_system(truncated) : standard_system
        claim_line = absence ? "(empty — a claim of ABSENCE: the reader asserts the source provides nothing for this key)" : render(value)
        [ { role: "system", content: system },
          { role: "user", content: <<~USER.strip } ]
            FACET: #{facet}
            CLAIM KEY: #{key}#{meaning ? "\nKEY MEANING (controlled vocabulary): #{meaning}" : ''}#{scope_note_lines(facet, key, context)}
            CLAIM VALUE: #{claim_line}

            SOURCE:
            #{source}
          USER
      end

      # v0.74: the SAME scope notes the reader was given, from the SAME source
      # (Vocabulary.scope_notes_for) — divergence between the reader and its
      # instrument is impossible by construction. The precondition matters MOST
      # here: an examiner judging an empty claim on a document where the key
      # does not apply must know that silence was the instructed behavior.
      # nil ⇒ empty string ⇒ the prompt is byte-identical (golden).
      def scope_note_lines(facet, key, context)
        note = Enliterator::Vocabulary.scope_notes_for(facet, context: context)&.dig(key.to_s)
        return "" unless note

        out = +""
        if (cond = note["applies_only_when"])
          out << "\nKEY APPLIES ONLY WHEN: #{cond}. On a document where this does not hold, " \
                 "an empty claim is the INSTRUCTED behavior and a value is suspect."
        end
        Array(note["not"]).each { |x| out << "\nKEY EXCLUDES: #{x}" }
        out
      end

      def standard_system
        <<~SYS.strip
          You are the QUALITY REVIEWER of a library catalog's claim store. Verify ONE
          claim against the source document, and render exactly one verdict:
            - supported: the source provides evidence for the claim's substance.
            - contradicted: the source provides evidence AGAINST the claim.
            - unsupported: the source is SILENT on the claim. Phrasing, style,
              completeness, or "I would have said it differently" are NEVER grounds
              for unsupported — only the absence of supporting evidence is.
            - unverifiable: this source cannot decide the claim (e.g. it concerns
              the document's relationships to other records you cannot see).
          Judge ONLY against the source text provided. Cite the source in your
          rationale. When contradicted, give the value the source actually supports.
        SYS
      end

      # The three coherent verdicts on a claim of absence. `supported` is
      # available ONLY when the caller vouched the source is complete
      # (truncated: false): an absence claim asserts something about the WHOLE
      # document, so a partial or unknown-completeness excerpt can refute it
      # but never confirm it. `unsupported` is incoherent here — before this
      # block existed the examiner coin-flipped supported/unsupported on
      # correct abstentions (91 empties: 42/46/3, identical rationales under
      # opposite labels).
      def absence_system(truncated)
        supported_line =
          case truncated
          when false
            "the source indeed provides nothing for this term. You have the COMPLETE source, so this verdict is available."
          when true
            "NOT AVAILABLE for this claim: the source you were given is TRUNCATED, and a partial excerpt can never confirm an absence — render unverifiable instead."
          else
            "NOT AVAILABLE for this claim: the completeness of the source you were given is UNKNOWN, and only a complete source can confirm an absence — render unverifiable instead."
          end
        <<~SYS.strip
          You are the QUALITY REVIEWER of a library catalog's claim store. This claim is
          a claim of ABSENCE: the reader asserted that the source provides NOTHING for
          this key. Verify that assertion against the source document, and render
          exactly one verdict:
            - supported: #{supported_line}
            - contradicted: the source DOES provide a value for this term — give the
              value it supports as corrected_value. Provable even from a partial excerpt.
            - unverifiable: the source provides no value for this term, but the absence
              cannot be confirmed (the source is incomplete, or cannot decide the claim).
          NEVER render unsupported: it is incoherent for a claim of absence — there is
          no positive assertion for the source to be silent about.
          Judge ONLY against the source text provided. Cite the source in your rationale.
        SYS
      end

      # Instruction-only enforcement leaves both off-doctrine verdicts
      # structurally reachable, so both are coerced — SYMMETRICALLY. Without
      # the supported-side coercion, abstention accuracy is inflatable by a
      # model ignoring one instruction: the coin flip's shape, rebuilt. Mirrors
      # the off-enum house style above (unknown verdict → unverifiable).
      def coerce_absence_verdict(verdict, truncated:, key:)
        coerced =
          if verdict == "unsupported"
            "unverifiable"
          elsif verdict == "supported" && truncated != false
            "unverifiable"
          end
        return verdict unless coerced

        Enliterator.configuration.logger&.info(
          "[enliterator] event=absence_verdict_coerced key=#{key} from=#{verdict} to=#{coerced} truncated=#{truncated.inspect}"
        )
        coerced
      end

      def render(value)
        value.is_a?(String) ? value : value.to_json
      end
    end
  end
end
