module Enliterator
  # Governed suggestion (SPEC.md > v0.3 > §3). When a facet has an output contract,
  # the model may not invent claim keys; instead it proposes additions here. The
  # ontology becomes a tended, governed thing — gaps surface where the vocabulary
  # is too narrow, and a human approves/maps/rejects each proposal.
  class Suggestion < ApplicationRecord
    belongs_to :tendable, polymorphic: true
    belongs_to :visit, class_name: "Enliterator::Visit", optional: true
    # v0.13: the context the proposal arose in. NULL = root (root rule). Verdicts
    # WRITE to their own context; suppression/approvals READ up the path — so a
    # root verdict inherits down, but a sibling context's verdict never leaks over.
    belongs_to :context, class_name: "Enliterator::Context", optional: true

    STATUSES = %w[pending approved mapped rejected].freeze

    scope :pending, -> { where(status: "pending") }

    # Proposed keys with ANY verdict (mapped/approved/rejected) VISIBLE from a
    # context — its own + every ancestor's + root (read-up, rule 4). v0.9 tending
    # suppresses re-proposals of these so the queue converges. `context: nil` ⇒
    # the root scope (NULL rows only — exactly the pre-v0.13 universe). Set of strings.
    def self.resolved_keys(context: nil)
      where.not(status: "pending")
        .where(context_id: context ? context.scope_ids : nil)
        .distinct.pluck(:proposed_key).to_set
    end

    # Aggregate open proposals into a ranked gap report: which keys are being asked
    # for most often, across how many distinct records, with a sample for context.
    # Scoped to pending; optionally narrowed to one facet. Ranked by demand desc.
    def self.gaps(facet: nil)
      rel = pending
      rel = rel.where(facet: facet) if facet

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

    # ---- batch verdicts (v0.7; context-scoped v0.13) ----------------------
    # The curatorial decision is about the VOCABULARY TERM, not each row — so
    # verdicts apply to every PENDING suggestion for a proposed_key at once,
    # WITHIN ONE CONTEXT (write-down, rule 4): a verdict in crs-reports never
    # resolves the same pending key in executive-orders. `context: nil` = root —
    # the entire pre-v0.13 universe, so existing callers behave identically.
    # Scoped to pending so a re-verdict never clobbers an already-decided row
    # (idempotent). Each returns the number of rows affected.

    def self.approve_key!(key, note: nil, context: nil)
      pending.where(proposed_key: key, context_id: context&.id)
             .update_all(status: "approved", review_note: note, updated_at: Time.current)
    end

    def self.map_key!(key, to:, note: nil, context: nil)
      pending.where(proposed_key: key, context_id: context&.id)
             .update_all(status: "mapped", mapped_to: to, review_note: note, updated_at: Time.current)
    end

    def self.reject_key!(key, note: nil, context: nil)
      pending.where(proposed_key: key, context_id: context&.id)
             .update_all(status: "rejected", review_note: note, updated_at: Time.current)
    end

    # Approved keys grouped by the facet that proposed them — the exact additions a
    # curator pastes into that facet's contract. `{facet => [proposed_key, ...]}`.
    def self.contract_additions
      where(status: "approved").distinct.pluck(:facet, :proposed_key)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq.sort }
    end

    # Recorded synonyms — proposed_key folded onto an existing canonical key.
    def self.synonyms
      where(status: "mapped").distinct.pluck(:facet, :proposed_key, :mapped_to)
        .map { |s, k, t| { facet: s, proposed_key: k, mapped_to: t } }
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
