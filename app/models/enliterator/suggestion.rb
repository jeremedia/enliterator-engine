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

    # Proposed keys with ANY verdict (mapped/approved/rejected). v0.9 tending
    # suppresses re-proposals of these so the queue converges. Set of strings.
    def self.resolved_keys
      where.not(status: "pending").distinct.pluck(:proposed_key).to_set
    end

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

    # ---- batch verdicts (v0.7) -------------------------------------------
    # The curatorial decision is about the VOCABULARY TERM, not each row — so
    # verdicts apply to every PENDING suggestion for a proposed_key at once. Scoped
    # to pending so a re-verdict never clobbers an already-decided row (idempotent).
    # Each returns the number of rows affected.

    def self.approve_key!(key, note: nil)
      pending.where(proposed_key: key).update_all(status: "approved", review_note: note, updated_at: Time.current)
    end

    def self.map_key!(key, to:, note: nil)
      pending.where(proposed_key: key).update_all(status: "mapped", mapped_to: to, review_note: note, updated_at: Time.current)
    end

    def self.reject_key!(key, note: nil)
      pending.where(proposed_key: key).update_all(status: "rejected", review_note: note, updated_at: Time.current)
    end

    # Approved keys grouped by the stream that proposed them — the exact additions a
    # curator pastes into that stream's contract. `{stream => [proposed_key, ...]}`.
    def self.contract_additions
      where(status: "approved").distinct.pluck(:stream, :proposed_key)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq.sort }
    end

    # Recorded synonyms — proposed_key folded onto an existing canonical key.
    def self.synonyms
      where(status: "mapped").distinct.pluck(:stream, :proposed_key, :mapped_to)
        .map { |s, k, t| { stream: s, proposed_key: k, mapped_to: t } }
    end

    # ---- per-row status setters — a human's governance verdict on one proposal ---
    def approve!(note: nil)
      update!(status: "approved", review_note: note)
    end

    # The proposed key maps onto an existing allowed key (a synonym, not a gap).
    # `to:` records the canonical key it folds into (v0.7).
    def map!(to: nil, note: nil)
      update!(status: "mapped", mapped_to: to, review_note: note)
    end

    def reject!(note: nil)
      update!(status: "rejected", review_note: note)
    end
  end
end
