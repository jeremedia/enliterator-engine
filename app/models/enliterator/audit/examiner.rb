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

        result = adapter.decide(
          messages:  messages_for(claim, facet, source),
          schema:    SCHEMA,
          tool_name: TOOL_NAME,
          tags:      [ "enliterator", "audit-examiner" ]
        )
        verdict = (result["verdict"] || result[:verdict]).to_s
        verdict = "unverifiable" unless Enliterator::Audit::VERDICTS.include?(verdict)

        Enliterator::Audit.create!(
          claim:            claim,
          verdict:          verdict,
          rationale:        (result["rationale"] || result[:rationale]).to_s,
          corrected_value:  (result["corrected_value"] || result[:corrected_value]).presence || {},
          confidence:       (result["confidence"] || result[:confidence]).to_f,
          source:           "examiner",
          auditor:          "#{effective_tier}:#{adapter.respond_to?(:model_id) ? adapter.model_id : 'unknown'}",
          heartbeat:        heartbeat,
          source_digest:    Digest::MD5.hexdigest(full),
          source_chars:     full.length,
          source_truncated: truncated
        )
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

      def messages_for(claim, facet, source)
        meaning = Enliterator::Vocabulary.for(facet, context: claim.context)&.dig(claim.key)
        [ { role: "system", content: <<~SYS.strip },
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
          { role: "user", content: <<~USER.strip } ]
            FACET: #{facet}
            CLAIM KEY: #{claim.key}#{meaning ? "\nKEY MEANING (controlled vocabulary): #{meaning}" : ''}
            CLAIM VALUE: #{render(claim.value)}

            SOURCE:
            #{source}
          USER
      end

      def render(value)
        value.is_a?(String) ? value : value.to_json
      end
    end
  end
end
