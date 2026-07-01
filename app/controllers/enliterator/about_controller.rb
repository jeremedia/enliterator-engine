module Enliterator
  # The About page — what enliteracy is, why the collection is tended, and how
  # compounding attention changes a collection now and over time.
  #
  # It is the demo surface AND the project's own north star (a living document).
  # It also renders a few LIVE numbers from the collection it is mounted on — the
  # page demonstrates the thesis by speaking about the very collection it explains.
  class AboutController < ApplicationController
    def index
      @stats = collection_stats
    end

    private

    # A small, resilient snapshot — pure counts, no network. Returns nil on any
    # failure so the explainer still renders its prose, and logs WHY (the live
    # strip is decoration; the page must never 500 on a host with odd data).
    def collection_stats
      policy = Enliterator.staffing
      {
        facets:        policy ? policy.assignments.keys : [],
        models:         Enliterator.mask_synthesized(Enliterator.tendable_models.map(&:name)),
        tended_records: Enliterator::Visit.where(status: "succeeded", applied: true)
                          .distinct.count(Arel.sql("tendable_type || ':' || tendable_id")),
        visits:         Enliterator::Visit.where(status: "succeeded").count,
        live_claims:    Enliterator::Claim.live.count,
        vocab_resolved: Enliterator::Suggestion.where.not(status: "pending").count,
        vocab_pending:  Enliterator::Suggestion.pending.count
      }
    rescue => e
      Rails.logger.warn("[enliterator] About stats unavailable: #{e.class}: #{e.message}")
      nil
    end
  end
end
