module Enliterator
  # v0.61: the revalidation DRAIN.
  #
  # v0.59 re-derive fires only on FUTURE source_change visits, so claims already
  # sedimented on a stable source (tended before the fix, or wrong from the start)
  # stay wrong on chapters that are never edited again. This drives a DELIBERATE
  # re-derive re-tend — Visit.reason "revalidate", which ALWAYS re-derives (the
  # invocation is the opt-in) — over the un-revalidated set, and measures the drain.
  #
  # No new table: the gauge keys on the Visit's `re_derived` flag (v0.61.1). A record
  # is "revalidated" for a (facet, context) once it has a succeeded applied visit that
  # actually RE-DERIVED there — whether by a deliberate revalidate drain OR an organic
  # source_change re-derive, so a chapter freshened by a real edit is credited, not
  # re-drained. Intended for bounded targets (a composite work / a named context), run
  # deliberately as a rake — not part of the pacemaker.
  module Revalidation
    module_function

    REASON = "revalidate".freeze

    # [[type, id], ...] still needing revalidation for (facet, context): records that have
    # been tended but have NO re-derived visit yet (tended − re-derived).
    def targets(facet:, context: nil)
      ctx_id = context&.id
      tended_tuples(facet: facet, context_id: ctx_id) - done_tuples(facet: facet, context_id: ctx_id)
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

    # Already re-derived: has a succeeded applied visit that actually re-derived
    # (re_derived = true) — a deliberate revalidate OR an organic source_change re-derive.
    def done_tuples(facet:, context_id:)
      base_scope(facet: facet, context_id: context_id)
        .where(re_derived: true).distinct.pluck(:tendable_type, :tendable_id)
    end

    def resolve(type, id)
      klass = type.safe_constantize
      klass&.find_by(klass.primary_key => id)
    end
  end
end
