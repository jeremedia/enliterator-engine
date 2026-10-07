module Enliterator
  module Mcp
    module Tools
      # The collection's measured accuracy — per facet and tier, with the
      # human-anchor agreement rate. This is what lets an agent SAY "the
      # authorship claims here audit at 95% supported" instead of hedging
      # uniformly. Process rates: audits never age out, re-tending can't
      # launder a number.
      class Accuracy < Tool
        name_and_description "accuracy",
          "The audited accuracy of the claim store: per facet/tier supported rates and the " \
          "examiner-vs-human agreement. Use these numbers to calibrate how strongly to " \
          "assert claims of each facet — and say them out loud when it matters."

        schema({})

        # v0.79: the listing reads this at call time, so the flag governs what the
        # agent is told. Flag-off: the v0.26 text, byte-identical.
        ATTRIBUTED_DESCRIPTION =
          "The audited accuracy of the claim store: per facet/tier supported rates and the " \
          "examiner-vs-human agreement. Use these numbers to judge how firmly to assert " \
          "claims of each facet. Report them to a patron only when they ask how reliable " \
          "something is, and then say what the figure measures.".freeze

        def self.description
          Enliterator.configuration.chat_attribution ? ATTRIBUTED_DESCRIPTION : super
        end

        def call
          {
            by_facet_and_tier: Enliterator::Audit.accuracy_cached,
            anchor_agreement:  Enliterator::Audit.anchor_agreement.except(:matrix),
            # v0.88: the examiner's agreement with itself, per facet — present
            # only once repeats exist (the instrument's reliability beside its rates).
            **instrument_agreement,
            verdict_meanings: {
              supported:    "the source provides evidence for the claim",
              unsupported:  "the source is silent on it",
              contradicted: "the source provides evidence against it",
              unverifiable: "this source cannot decide it"
            },
            next: { flag_claim: "file a suspect claim for human review",
                    human_view: "/enliterator/review" }
          }
        end

        private

        def instrument_agreement
          rows = Enliterator::AuditRepeat.agreement
          return {} if rows.empty?

          { instrument_agreement: {
              by_facet: rows,
              meaning: "how often the examiner, asked again about the same unchanged source under the " \
                       "same configuration, gives the same verdict — the instrument's reliability, not the " \
                       "claims' accuracy"
          } }
        end
      end
    end
  end
end
