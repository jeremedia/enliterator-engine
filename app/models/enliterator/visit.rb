module Enliterator
  # PROV Activity. One tending pass over a record along a stream. Immutable
  # history: each visit reads prior visits + claims + neighbors and reconciles.
  # The accumulation of Visits is what makes understanding compound (rung 5).
  class Visit < ApplicationRecord
    belongs_to :tendable, polymorphic: true
    has_many :claims, class_name: "Enliterator::Claim", foreign_key: :visit_id, dependent: :nullify, inverse_of: :visit

    STATUSES = %w[pending running succeeded failed].freeze

    # Compact projection for prompt context handed to the next visit.
    def to_state
      {
        stream:     stream,
        confidence: confidence,
        summary:    reconciliation,
        at:         created_at
      }
    end
  end
end
