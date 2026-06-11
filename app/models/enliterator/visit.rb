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

    STATUSES = %w[pending running succeeded failed].freeze

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
