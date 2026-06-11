module Enliterator
  module Mcp
    module Tools
      # The agent as EYES for the immune system: flag a suspect claim for
      # human review. Files an Audit with source "agent" — visible in
      # provenance and on /review's agent-flagged strip, but carrying ZERO
      # weight in the accuracy instrument (the v0.26 scoping rule): the
      # flag's whole purpose is to reach a human, never to be a verdict.
      class FlagClaim < Tool
        name_and_description "flag_claim",
          "Flag a claim for human review with your suspected verdict and reasoning. " \
          "This files an agent audit — it changes no accuracy number and never edits " \
          "the claim; a human renders the verdict on /enliterator/review."

        schema({
          "claim_id" => int("The claim id (from record_entry / provenance)"),
          "verdict"  => str("Your suspected verdict: unsupported, contradicted, or unverifiable"),
          "note"     => str("What you observed — cite the evidence that raised the flag")
        }, required: [ :claim_id, :verdict, :note ])

        FLAGGABLE = %w[unsupported contradicted unverifiable].freeze

        def call(claim_id:, verdict:, note:)
          claim = Enliterator::Claim.find_by(id: claim_id) ||
                  raise(ArgumentError, "no claim ##{claim_id}")
          unless FLAGGABLE.include?(verdict.to_s)
            raise ArgumentError, "verdict must be one of: #{FLAGGABLE.join(', ')} " \
                                 "(a supported claim needs no flag)"
          end

          audit = Enliterator::Audit.create!(
            claim:     claim,
            source:    "agent",
            auditor:   "mcp-agent",
            verdict:   verdict.to_s,
            rationale: note.to_s
          )

          {
            flagged:  true,
            audit_id: audit.id,
            claim:    { id: claim.id, key: claim.key, value: render_value(claim.value) },
            weight:   "none — agent flags never count toward accuracy; a human reviews on /enliterator/review",
            next:     { human_view: "/enliterator/review" }
          }
        end
      end
    end
  end
end
