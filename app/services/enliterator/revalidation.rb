module Enliterator
  # v0.61: the revalidation DRAIN.
  #
  # v0.59 re-derive fires only on FUTURE source_change visits, so claims already
  # sedimented on a stable source (tended before the fix, or wrong from the start)
  # stay wrong on chapters that are never edited again. This drives a DELIBERATE
  # re-derive re-tend — Visit.reason "revalidate", which ALWAYS re-derives (the
  # invocation is the opt-in) — over the un-revalidated set, and measures the drain.
  #
  # No new column: the revalidate Visit row IS the mark. A record is "revalidated"
  # for a (facet, context) once it has a succeeded, applied revalidate visit there;
  # progress is a visit query. Intended for bounded targets (a composite work / a
  # named context), run deliberately as a rake — not part of the pacemaker.
  module Revalidation
    module_function

    REASON = "revalidate".freeze

    # [[type, id], ...] still needing revalidation for (facet, context): records with a
    # succeeded applied NON-revalidate visit but NO succeeded revalidate visit yet.
    def targets(facet:, context: nil)
      ctx_id = context&.id
      candidate_tuples(facet: facet, context_id: ctx_id) - done_tuples(facet: facet, context_id: ctx_id)
    end

    # { total:, revalidated:, remaining: } for (facet, context) — the drain gauge.
    # total = every record tended for this lane (the denominator, incl. already-drained).
    def progress(facet:, context: nil)
      ctx_id = context&.id
      total = tended_tuples(facet: facet, context_id: ctx_id).size
      done  = done_tuples(facet: facet, context_id: ctx_id).size
      { total: total, revalidated: done, remaining: total - done }
    end

    # Enqueue a revalidate (re-derive) re-tend for up to `limit` un-revalidated records
    # of (facet, context). Returns the count enqueued. The host queue must be running to
    # process them; each visit re-derives, superseding a stale claim and NOOP-confirming
    # a still-correct one. A record with no resolvable host row is skipped.
    def run(facet:, context: nil, limit: nil)
      picks = targets(facet: facet, context: context)
      picks = picks.first(limit) if limit

      enqueued = 0
      picks.each do |type, id|
        record = resolve(type, id) or next
        Enliterator::TendingVisitJob.perform_later(record, facet.to_s, context, reason: REASON)
        enqueued += 1
      end
      enqueued
    end

    # ---- internals -------------------------------------------------------

    def base_scope(facet:, context_id:)
      Enliterator::Visit.applied.where(facet: facet.to_s, status: "succeeded", context_id: context_id)
    end

    # Every record with a succeeded applied visit for this lane (the denominator).
    def tended_tuples(facet:, context_id:)
      base_scope(facet: facet, context_id: context_id).distinct.pluck(:tendable_type, :tendable_id)
    end

    # Candidates: tended by something OTHER than a revalidate visit — reason NULL
    # (legacy/manual, i.e. sedimented) or any non-revalidate reason. (Postgres
    # IS DISTINCT FROM so a NULL reason counts as a candidate.)
    def candidate_tuples(facet:, context_id:)
      base_scope(facet: facet, context_id: context_id)
        .where("reason IS DISTINCT FROM ?", REASON)
        .distinct.pluck(:tendable_type, :tendable_id)
    end

    # Already drained: has a succeeded applied revalidate visit for this lane.
    def done_tuples(facet:, context_id:)
      base_scope(facet: facet, context_id: context_id)
        .where(reason: REASON).distinct.pluck(:tendable_type, :tendable_id)
    end

    def resolve(type, id)
      klass = type.safe_constantize
      klass&.find_by(klass.primary_key => id)
    end
  end
end
