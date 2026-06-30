module Enliterator
  # Governed suggestion. When a facet has an output contract,
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
    # Scoped to pending; optionally narrowed to one facet and/or one collection
    # context (v0.13: a context's queue shows the proposals that arose IN it —
    # pending rows don't inherit; only VERDICTS read up the path). Ranked by demand.
    def self.gaps(facet: nil, context: :__all__)
      rel = pending
      rel = rel.where(facet: facet) if facet
      rel = rel.where(context_id: context&.id) unless context == :__all__

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

    # ---- curator corrections (v0.52) — re-adjudicate ALREADY-RESOLVED rows ----
    # The verdict trio above is pending-scoped (idempotent — a re-verdict never clobbers a
    # decided row). These operate on RESOLVED rows, so a curator can fix a mis-fold from the
    # /vocabulary surface instead of raw SQL. ALL are context-scoped (rule 4 — write to own
    # context, never a sibling), set updated_at (update_all skips auto-timestamps), and return
    # the affected-row count (the controller alerts on 0). Pure-metadata vs vocabulary-changing
    # is noted per method. Targets are validated against the effective vocabulary by the CALLER
    # (it has Authority#canonical_keys + flash); the integrity invariants that don't depend on
    # the UI (a legal to_status, no dangling demote-to-mapped) are enforced here too.

    # Re-point one variant's USE target (a mapped row) onto a different preferred term. PURE
    # METADATA — mapped_to is read only for display + never feeds Vocabulary.for. Also the
    # per-variant primitive behind a UI "split" (peel a variant off its ring).
    def self.reroute_key!(key, to:, context: nil)
      where(status: "mapped", proposed_key: key, context_id: context&.id)
        .update_all(mapped_to: to, updated_at: Time.current)
    end

    # Promote a mapped/rejected variant to a PREFERRED (approved) term — it joins Vocabulary.for
    # (the model may emit it as a claim key).
    def self.promote_key!(key, context: nil)
      where(status: %w[mapped rejected], proposed_key: key, context_id: context&.id)
        .update_all(status: "approved", mapped_to: nil, updated_at: Time.current)
    end

    # Demote a preferred (approved) term: → "rejected" (mapped_to cleared) or → "mapped" (folded
    # onto `to`). Removes the key's DB contribution from Vocabulary.for (a term ALSO code-defined
    # stays — code wins). `to_status` is a data-integrity invariant (update_all skips validations,
    # status has no DB enum) — raise on anything else; demote-to-mapped REQUIRES a target (no
    # dangling USE-reference).
    def self.demote_key!(key, to_status:, to: nil, context: nil)
      raise ArgumentError, "to_status must be 'mapped' or 'rejected'" unless %w[mapped rejected].include?(to_status)
      raise ArgumentError, "demote to 'mapped' needs a target" if to_status == "mapped" && to.blank?
      attrs = { status: to_status, mapped_to: (to_status == "mapped" ? to : nil), updated_at: Time.current }
      where(status: "approved", proposed_key: key, context_id: context&.id).update_all(attrs)
    end

    # Fold the whole `from` ring onto `into` in one transaction: (1) re-point every variant folded
    # onto `from` (rows where mapped_to == from — which no by-proposed_key primitive selects), then
    # (2) fold `from`'s OWN rows onto `into`, EXCLUDING rejected (a deliberately-killed proposal is
    # never resurrected as a synonym). Returns total rows touched. `into` must be a preferred term
    # (caller validates against canonical_keys).
    def self.merge_keys!(from:, into:, context: nil)
      transaction do
        a = where(status: "mapped", mapped_to: from, context_id: context&.id)
              .update_all(mapped_to: into, updated_at: Time.current)
        b = where(proposed_key: from, context_id: context&.id).where.not(status: "rejected")
              .update_all(status: "mapped", mapped_to: into, updated_at: Time.current)
        a + b
      end
    end

    # Peel a NAMED SUBSET of `key`'s variants (those folded onto `key`) onto a different preferred
    # term. The batch form of reroute; the UI peels one variant at a time via reroute_key!.
    def self.split_key!(key, move:, to:, context: nil)
      where(status: "mapped", mapped_to: key, proposed_key: Array(move), context_id: context&.id)
        .update_all(mapped_to: to, updated_at: Time.current)
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
