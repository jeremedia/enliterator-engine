module Enliterator
  # PROV Activity. One tending pass over a record along a facet. Immutable
  # history: each visit reads prior visits + claims + neighbors and reconciles.
  # The accumulation of Visits is what makes understanding compound (rung 5).
  class Visit < ApplicationRecord
    belongs_to :tendable, polymorphic: true
    # v0.13: the context this pass tended within. NULL = the root scope (root rule).
    belongs_to :context, class_name: "Enliterator::Context", optional: true
    # v0.15: the heartbeat cycle that caused this visit (+ `reason` column: why it
    # was scheduled). NULL for every manual/legacy tend — provenance, never gating.
    belongs_to :heartbeat, class_name: "Enliterator::Heartbeat", optional: true
    has_many :claims, class_name: "Enliterator::Claim", foreign_key: :visit_id, dependent: :nullify, inverse_of: :visit

    # Escalation chain (v0.2 staffing): a senior visit points back to the junior
    # visit it was promoted from; the junior gains a back-reference.
    belongs_to :escalated_from, class_name: "Enliterator::Visit", optional: true
    has_many :escalations, class_name: "Enliterator::Visit", foreign_key: :escalated_from_id, dependent: :nullify, inverse_of: :escalated_from

    # v0.90.1: `deferred` — attempted while the backend was transiently
    # unavailable (expired gateway credential, timeout, 5xx); nothing was
    # learned. Distinct from `failed` so the planner's failure backoff does not
    # hold the record back from the very next beat.
    STATUSES = %w[pending running succeeded failed deferred].freeze

    # Visits whose reconciliation was actually applied (the final tier in a loop).
    # Junior visits superseded by escalation are recorded with applied: false.
    scope :applied, -> { where(applied: true) }

    # v0.25: the HOST tendable types in the visit log — the "Registry ∪ visit
    # log" authority rule's log side, in ONE place. Engine-internal tendables
    # (Enliterator::Part) are excluded by name: parts are tended and their
    # visits are real provenance, but they must never be resurrected into the
    # planner's root lanes, the corpus census, the survey, or Settings.
    def self.host_tendable_types
      distinct.where("tendable_type NOT LIKE 'Enliterator::%'")
              .pluck(:tendable_type).compact
    end

    # v0.77: a running visit with no sign of life past the cycle reaper's
    # window is an ORPHAN — its process died (kill, restart, crash) before it
    # could stamp itself. Two shapes: a heartbeat-LESS tend (a rake, a runner,
    # a manual `tend!`) has no cycle row to be reaped through; a visit under a
    # cycle that has already FINISHED (normally or by reaping) cannot still be
    # in flight — its process is gone by definition. A visit under a LIVE cycle
    # is left alone whatever its age: the cycle's pulse vouches for it, and the
    # cycle reaper decides when that vouching ends.
    scope :orphaned, -> {
      where(status: "running")
        .where("COALESCE(enliterator_visits.updated_at, enliterator_visits.started_at) < ?",
               Enliterator::Heartbeat::REAP_AFTER.ago)
        .where("enliterator_visits.heartbeat_id IS NULL OR EXISTS (" \
               "SELECT 1 FROM enliterator_heartbeats h " \
               "WHERE h.id = enliterator_visits.heartbeat_id AND h.finished_at IS NOT NULL)")
    }

    # Stamp every orphaned visit with an honest ending. Returns the reaped
    # rows. Rides Heartbeat.reap_orphans! (every beat, the monitor page) so a
    # host never needs a runner script to bury a dead manual tend. Writes
    # nothing when nothing is orphaned (byte-identical for a clean ledger).
    def self.reap_orphans!
      orphaned.order(:id).map(&:reap!)
    end

    def reap!
      last_life = updated_at || started_at || created_at
      now       = Time.current
      update_columns(
        status:      "failed",
        finished_at: last_life,
        error:       "orphaned: the tending process ended before this visit finished " \
                     "(last sign of life #{last_life.iso8601}); reaped #{now.iso8601}",
        updated_at:  now
      )
      Rails.logger.warn("[enliterator] visit ##{id} (#{tendable_type}/#{tendable_id} #{facet}) reaped: " \
                        "orphaned, last sign of life #{last_life.iso8601}")
      self
    end

    # Compact projection for prompt context handed to the next visit.
    def to_state
      {
        facet:     facet,
        tier:       tier,
        confidence: confidence,
        summary:    reconciliation,
        at:         created_at
      }
    end
  end
end
