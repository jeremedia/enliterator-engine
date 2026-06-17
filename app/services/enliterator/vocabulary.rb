module Enliterator
  # The effective CONTROLLED VOCABULARY for a facet — the terms the model is
  # actually permitted to assert. It is the CODE vocabulary (the staffing policy's
  # `terms_for`) plus any AUTHORIZED terms a curator adopted (v0.9 convergence): once
  # a proposed term is approved, it joins the vocabulary so the model emits it as a
  # claim instead of re-proposing it.
  #
  # This is authority control. The code vocabulary is the established term list; the
  # approved extension is DERIVED from approval verdicts (approved Suggestions), so
  # it's auditable and dumpable — and the review queue still surfaces the code diff,
  # so an authorized term can be codified into the policy permanently (after which
  # the DB derivation is redundant). Code-defined terms always win on a name conflict.
  #
  # When nothing is approved (or `apply_approved_keys` is false), `Vocabulary.for`
  # returns exactly `staffing.terms_for(facet)` — including `nil` for an
  # unconstrained facet — so the path stays byte-identical to v0.3/v0.8.
  module Vocabulary
    module_function

    DEFAULT_DESCRIPTION = "Approved vocabulary term."

    # v0.13: context-aware. Code terms resolve along the context's policy path
    # (a child's declaration wins); curator approvals READ UP THE PATH (rule 4)
    # — a root/ancestor approval inherits down, a sibling's never leaks over.
    # `context: nil` ⇒ the root scope, byte-identical to v0.12.
    #
    # @return [Hash{String=>String}, nil] effective {term => description}, or nil
    #   when the facet is unconstrained (open terms) and has no authorized terms.
    def for(facet, context: nil)
      code = Enliterator.staffing.terms_for(facet, path: context&.path_keys)  # Hash or nil
      return code unless Enliterator.configuration.apply_approved_keys

      ext = approved_extension(facet, context: context)
      return code if ext.empty?

      merged = (code || {}).dup
      ext.each { |term, desc| merged[term] ||= desc }         # code terms win
      merged
    end

    # Terms a curator AUTHORIZED for this facet — visible from `context` (its
    # own + ancestors + root NULL) — with a description (the term's considerer
    # rationale, else a default). {} when none.
    def approved_extension(facet, context: nil)
      terms = Enliterator::Suggestion
                .where(facet: facet.to_s, status: "approved",
                       context_id: context ? context.scope_ids : nil)
                .distinct.pluck(:proposed_key)
      return {} if terms.empty?

      descs = Enliterator::ProposedTerm.where(proposed_key: terms).pluck(:proposed_key, :recommended_rationale).to_h
      terms.each_with_object({}) { |t, h| h[t] = descs[t].presence || DEFAULT_DESCRIPTION }
    end

    # Stage 1 — read-time warrant accrual. The bounded, warrant-ranked CANDIDATE
    # vocabulary a reader is shown for a facet/context: live PENDING proposals
    # (`Suggestion.gaps`, demand-ranked) MINUS what is already established or
    # resolved. Read off LIVE pending — NOT `ProposedTerm`, which is refreshed only
    # at considerer time and so would be stale/empty in the tend loop.
    #
    # Scoping is asymmetric: gathering is EXACT-context (`gaps`' own `context_id:`
    # filter — pending rows don't inherit, SPEC rule 4); exclusion is PATH-CUMULATIVE
    # (`Vocabulary.for` + `resolved_keys` both read up the path — verdicts/approvals
    # inherit down). Excludes `resolved_keys` (approved/mapped/rejected), not just the
    # established set, so a key whose affirmation `persist_suggestions!` would suppress
    # is never advertised as a live candidate.
    #
    # +established+ lets a caller (the visitor) pass the contract it ALREADY resolved
    # via `Vocabulary.for`, to avoid recomputing it per record; nil falls back to
    # `Vocabulary.for` for standalone/test callers. Keys are string-normalized
    # (a contract may be symbol-keyed) so the set-difference against the String
    # `proposed_key`s from `gaps` actually matches.
    #
    # @return [Array<Hash>, nil] up to `limit` gap hashes {proposed_key, count,
    #   sample_rationale, sample_example} by demand; nil (NOT []) when none, so the
    #   visitor's `!candidates.nil?` gate omits the kwarg and the call stays
    #   byte-identical when there is nothing to show.
    def candidates_for(facet, context: nil, established: nil, limit: 20)
      est      = ((established || Enliterator::Vocabulary.for(facet, context: context)) || {})
                   .keys.map(&:to_s).to_set
      excluded = est + Enliterator::Suggestion.resolved_keys(context: context)
      Enliterator::Suggestion.gaps(facet: facet.to_s, context: context)
        .reject { |g| excluded.include?(g[:proposed_key]) }
        .first(limit)
        .presence
    end
  end
end
