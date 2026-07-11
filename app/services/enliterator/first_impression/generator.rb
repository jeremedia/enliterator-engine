require "set"

module Enliterator
  module FirstImpression
    # Generates a grounded question set for one record. The model only PHRASES
    # questions; the answer keys stay grounded in the record's real surrogate and
    # claims. A mechanical grounding check then flags leakage — a `coverage` key
    # whose answer is actually in the surrogate (so it wouldn't discriminate) or a
    # `reading` key that isn't (mis-typed). Keys are never invented by the judge.
    class Generator
      TOOL_NAME = "emit_questions".freeze

      # Coverage questions whose answer is sourced from an analytical facet are the
      # "deep" subset — the findings only a deep reading of the full source holds.
      DEEP_FACETS = %w[evidence_base key_findings limitations methodology].freeze

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "questions" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "properties" => {
                "id"       => { "type" => "string" },
                "type"     => { "type" => "string", "enum" => %w[reading coverage reliability trap] },
                "question" => { "type" => "string" },
                "ideal"    => { "type" => "string", "description" => "the correct answer, grounded in the given text/claims" },
                "source"   => { "type" => "string", "description" => "surrogate | <claim key> | limitations | absent" }
              },
              "required" => %w[id type question ideal]
            }
          }
        },
        "required" => %w[questions]
      }.freeze

      STOPWORDS = Set.new(%w[
        the a an of to in on for and or is are was were be as by with from at this that it its
        which who whom whose what how many much does do did will would should could may might
        study thesis report author standard approach used uses using based their they them
        provides provide recommends recommend federal
      ]).freeze

      def initialize(llm: nil, tier: nil)
        @llm  = llm
        @tier = tier
      end

      # @return [Array<Hash>] questions, each {id, type, question, ideal, source, deep, grounding}
      def generate(record, claims:)
        surrogate = record.enliterator_text.to_s
        result = Enliterator::FirstImpression.structured(
          resolve_llm,
          messages:  messages_for(surrogate, claims),
          schema:    SCHEMA,
          tool_name: TOOL_NAME,
          tags:      [ "enliterator", "first-impression-generate" ]
        )
        Array(result["questions"] || result[:questions]).map { |q| annotate(stringify(q), surrogate) }
      end

      private

      def resolve_llm
        @llm || Enliterator.llm(tier: @tier || Enliterator.configuration.first_impression_generate_tier ||
                                     Enliterator.staffing&.ladder&.last || "quality")
      end

      def stringify(q)
        q.transform_keys(&:to_s)
      end

      # Attach the deep flag + a grounding verdict (advisory — the confound canary in
      # the report is the real guard). A crude token-overlap check: it can false-warn
      # on domain-heavy answers, so it flags for review, never drops.
      def annotate(q, surrogate)
        deep = DEEP_FACETS.include?(q["source"].to_s)
        grounding =
          case q["type"]
          when "coverage"
            surrogate_absent?(q["ideal"], surrogate) ? "ok" : "warn: coverage key appears in surrogate"
          when "reading"
            surrogate_absent?(q["ideal"], surrogate) ? "warn: reading key not in surrogate" : "ok"
          else "ok"
          end
        q.merge("deep" => deep, "grounding" => grounding)
      end

      def surrogate_absent?(answer, surrogate)
        sig  = significant(answer)
        return false if sig.empty?
        surr = tokens(surrogate)
        (sig & surr).size.to_f / sig.size < 0.4
      end

      def tokens(s)
        s.to_s.downcase.scan(/[a-z0-9]+/).to_set - STOPWORDS
      end

      def significant(value)
        tokens(value).select { |t| t.length >= 4 || t.match?(/\A\d+\z/) }.to_set
      end

      def render_claims(claims)
        claims.map { |c| "- #{c.key}: #{Enliterator::Trajectory.render(c.value)}" }.join("\n")
      end

      SYSTEM = <<~SYS.strip
        You build a grounded question set to test whether a reader who has ONLY a record's
        catalog abstract can answer questions about it, versus a reader who also has the engine's
        structured claims (a deep reading of the full source).
      SYS

      def messages_for(surrogate, claims)
        user = <<~USER.strip
          ABSTRACT (the surrogate a catalog reader gets):
          #{surrogate}

          STRUCTURED CLAIMS (from a deep reading of the full source; many hold detail the abstract omits):
          #{render_claims(claims)}

          Generate exactly:
          - 4 "reading" questions whose answer is clearly stated IN THE ABSTRACT. ideal = that answer.
          - 6 "coverage" questions whose answer is a SPECIFIC fact found in the CLAIMS but NOT in the
            abstract (author, dates, scope/numbers, findings, methods, data limits). ideal = the exact
            fact FROM THE CLAIM (do not paraphrase away specifics). Prefer the deep facets:
            evidence_base, key_findings, limitations, methodology, authored_by, advisor. Set source to
            the claim key.
          - 2 "reliability" questions asking HOW MUCH a reader should trust the record's main conclusion
            or recommendation. ideal = an appropriately CAUTIOUS answer citing the real caveats in the
            'limitations' claim (sample size, data window, narrow scope). source = "limitations".
          - 2 "trap" questions asking about a plausible detail the record does NOT address (a dollar
            cost-benefit figure, a regional breakdown, a staffing recommendation — not in the abstract
            or claims). ideal = "The record does not address this." source = "absent".

          Number ids: reading a1-a4, coverage b1-b6, reliability r1-r2, trap c1-c2.
        USER
        [ { role: "system", content: SYSTEM }, { role: "user", content: user } ]
      end
    end
  end
end
