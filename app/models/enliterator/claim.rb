module Enliterator
  # PROV Entity. A provenanced, reconcilable unit of understanding about a record.
  # Claims are never edited in place; an UPDATE creates a new Claim and supersedes
  # the old one, preserving the provenance chain (prov:wasDerivedFrom).
  class Claim < ApplicationRecord
    belongs_to :tendable, polymorphic: true
    belongs_to :visit, class_name: "Enliterator::Visit", optional: true
    belongs_to :superseded_by, class_name: "Enliterator::Claim", optional: true
    # v0.13: the context this claim is asserted WITHIN. NULL = the root scope
    # (root rule) — true of the record in every lens, inherited by all contexts.
    belongs_to :context, class_name: "Enliterator::Context", optional: true

    STATUSES = %w[draft verified superseded].freeze
    REVIEW_STATES = %w[pending approved rejected].freeze

    # The latest claim in a supersession chain.
    scope :current, -> { where(superseded_by_id: nil) }
    # Current AND not tombstoned (a DELETE supersedes without a replacement).
    scope :live,    -> { current.where.not(status: "superseded") }

    # Compact projection for literacy_state / prompt context.
    def to_state
      {
        key:        key,
        value:      value,
        confidence: confidence,
        status:     status,
        locked:     locked
      }
    end

    # Mark this claim superseded by a newer one. Used by the reconcile contract on
    # UPDATE (replacement) — locked claims are protected upstream in the Visitor.
    def supersede!(by_claim)
      update!(status: "superseded", superseded_by: by_claim)
    end
  end
end
