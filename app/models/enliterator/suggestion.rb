module Enliterator
  # Governed suggestion (SPEC.md > v0.3 > §3). When a stream has an output contract,
  # the model may not invent claim keys; instead it proposes additions here. The
  # ontology becomes a tended, governed thing — gaps surface where the vocabulary
  # is too narrow, and a human approves/maps/rejects each proposal.
  class Suggestion < ApplicationRecord
    belongs_to :tendable, polymorphic: true
    belongs_to :visit, class_name: "Enliterator::Visit", optional: true

    STATUSES = %w[pending approved mapped rejected].freeze

    scope :pending, -> { where(status: "pending") }

    # Aggregate open proposals into a ranked gap report: which keys are being asked
    # for most often, across how many distinct records, with a sample for context.
    # Scoped to pending; optionally narrowed to one stream. Ranked by demand desc.
    def self.gaps(stream: nil)
      rel = pending
      rel = rel.where(stream: stream) if stream

      rel.group(:proposed_key).pluck(
        Arel.sql("proposed_key"),
        Arel.sql("COUNT(DISTINCT (tendable_type || ':' || tendable_id))"),
        Arel.sql("(ARRAY_AGG(rationale ORDER BY id))[1]"),
        Arel.sql("(ARRAY_AGG(example_value ORDER BY id))[1]")
      ).map { |key, count, rationale, example|
        {
          proposed_key:     key,
          count:            count,
          sample_rationale: rationale,
          sample_example:   example
        }
      }.sort_by { |g| -g[:count] }
    end

    # Status setters — a human's governance verdict on the proposal.
    def approve!(note: nil)
      update!(status: "approved", review_note: note)
    end

    # The proposed key maps onto an existing allowed key (a synonym, not a gap).
    def map!(note: nil)
      update!(status: "mapped", review_note: note)
    end

    def reject!(note: nil)
      update!(status: "rejected", review_note: note)
    end
  end
end
