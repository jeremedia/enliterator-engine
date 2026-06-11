module Enliterator
  module Mcp
    module Tools
      # "How do you know that?" — one claim's full chain: the visit that
      # minted it (tier, model, reason, what it read), what it derived from,
      # what superseded what, and every audit verdict rendered on it. The
      # answer that makes an agent's citations trustworthy.
      class Provenance < Tool
        name_and_description "provenance",
          "A claim's full provenance: the minting visit (tier/model/reason/inputs), " \
          "derivation chain, supersession in both directions, and all audit verdicts " \
          "(examiner, human, agent). Call before asserting anything load-bearing."

        schema({
          "claim_id" => int("The claim id (from record_entry)")
        }, required: [ :claim_id ])

        def call(claim_id:)
          claim = Enliterator::Claim.find_by(id: claim_id) ||
                  raise(ArgumentError, "no claim ##{claim_id}")
          visit = claim.visit
          record = claim.tendable

          {
            claim: claim_card(claim),
            record: record && { type: claim.tendable_type, id: claim.tendable_id,
                                label: label_for(record), entry: entry_path(claim.tendable_type, claim.tendable_id) },
            visit: visit && {
              id: visit.id, facet: visit.facet, tier: visit.tier, model: visit.model,
              reason: visit.reason, at: visit.created_at,
              escalation_step: visit.escalation_step,
              inputs: visit.input_refs
            }.compact,
            derived_from: claim.derived_from.presence,
            supersedes: Enliterator::Claim.where(superseded_by_id: claim.id).pluck(:id),
            superseded_by: claim.superseded_by_id,
            audits: claim_audits(claim),
            next: { quote: "the source passage this claim was read from" }
          }.compact
        end

        private

        def claim_audits(claim)
          Enliterator::Audit.where(claim_id: claim.id).order(:created_at).map do |a|
            { source: a.source, auditor: a.auditor, verdict: a.verdict,
              rationale: render_value(a.rationale, cap: 300), at: a.created_at,
              source_truncated: a.source_truncated || nil }.compact
          end
        end
      end
    end
  end
end
