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

        def call
          {
            by_facet_and_tier: Enliterator::Audit.accuracy,
            anchor_agreement:  Enliterator::Audit.anchor_agreement.except(:matrix),
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
      end
    end
  end
end
