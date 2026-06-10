module Enliterator
  # The materialized pressure aggregate for a proposed vocabulary key — the
  # term-level view the considerer reasons over. One row per proposed_key,
  # recomputed from the immutable Suggestion proposal log.
  #
  # PRESSURE is the integral of demand: total proposals ever for the key.
  # RESURGED_COUNT is the count of proposals that came back AFTER a verdict — the
  # model overruling the curator, the strongest evidence the contract is wrong.
  #
  # ProposedTerm is ADDITIVE: the verdict authority + contract_additions/synonyms
  # stay on Suggestion (v0.7). This model adds pressure + the considerer's
  # held-for-ratification recommendation; refresh! never clobbers recommendation_*.
  class ProposedTerm < ApplicationRecord
    scope :by_pressure, -> { order(pressure: :desc, proposed_key: :asc) }
    scope :resurged,    -> { where("resurged_count > 0") }
    # Terms that still have unresolved (pending) proposals.
    scope :open, -> { where(proposed_key: Enliterator::Suggestion.pending.select(:proposed_key)) }

    # Columns refresh! overwrites on conflict. updated_at is managed by upsert_all
    # automatically (listing it here would double-assign the column). The
    # recommended_* columns are intentionally EXCLUDED so a stored recommendation
    # survives a refresh.
    PRESSURE_COLS = %i[pressure distinct_records by_facet resurged_count
                       first_seen_at last_seen_at sample_rationale sample_example].freeze

    # Recompute every term's pressure from the Suggestion log. Idempotent; preserves
    # any considerer recommendation on existing rows (update_only excludes those cols).
    # Returns the number of terms upserted.
    def self.refresh!
      sugg = Enliterator::Suggestion
      keys = sugg.distinct.pluck(:proposed_key).compact
      return 0 if keys.empty?

      pressures   = sugg.group(:proposed_key).count
      distincts   = sugg.group(:proposed_key).distinct.count(Arel.sql("tendable_type || ':' || tendable_id"))
      firsts      = sugg.group(:proposed_key).minimum(:created_at)
      lasts       = sugg.group(:proposed_key).maximum(:created_at)
      resolved_at = sugg.where.not(status: "pending").group(:proposed_key).maximum(:updated_at)
      by_facet   = sugg.group(:proposed_key, :facet).count.each_with_object({}) do |((k, s), n), h|
        (h[k] ||= {})[s.to_s] = n
      end
      samples = sugg.select("DISTINCT ON (proposed_key) proposed_key, rationale, example_value")
                    .order(:proposed_key, :id)
                    .each_with_object({}) { |s, h| h[s.proposed_key] = [ s.rationale, s.example_value ] }
      # resurged = pending proposals created after the key's most recent verdict.
      # ONE join against the per-key cutoffs — a per-key COUNT in the loop below
      # was the /requests page's N+1 (one query per resolved key, ~300 on HSDL).
      resurged_counts = sugg.pending
                            .joins(<<~SQL)
                              JOIN (SELECT proposed_key, MAX(updated_at) AS cut
                                    FROM enliterator_suggestions
                                    WHERE status <> 'pending'
                                    GROUP BY proposed_key) verdicts
                                ON verdicts.proposed_key = enliterator_suggestions.proposed_key
                               AND enliterator_suggestions.created_at > verdicts.cut
                            SQL
                            .group(:proposed_key).count

      now = Time.current
      rows = keys.map do |key|
        resurged = resolved_at[key] ? resurged_counts[key].to_i : 0
        rationale, example = samples[key]
        {
          proposed_key:     key,
          pressure:         pressures[key].to_i,
          distinct_records: distincts[key].to_i,
          by_facet:        (by_facet[key] || {}),
          resurged_count:   resurged,
          first_seen_at:    firsts[key],
          last_seen_at:     lasts[key],
          sample_rationale: rationale,
          sample_example:   (example || {}),
          created_at:       now,
          updated_at:       now
        }
      end

      upsert_all(rows, unique_by: :proposed_key, update_only: PRESSURE_COLS)
      rows.size
    end

    def record_recommendation!(decision:, map_to: nil, rationale: nil, confidence: nil)
      update!(
        recommended_decision:   decision,
        recommended_map_to:     map_to,
        recommended_rationale:  rationale,
        recommended_confidence: confidence,
        considered_at:          Time.current
      )
    end

    def clear_recommendation!
      update!(recommended_decision: nil, recommended_map_to: nil,
              recommended_rationale: nil, recommended_confidence: nil)
    end
  end
end
