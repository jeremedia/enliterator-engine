module Enliterator
  # The effective CONTROLLED VOCABULARY for a stream — the terms the model is
  # actually permitted to assert. It is the CODE vocabulary (the staffing policy's
  # `keys_for`) plus any AUTHORIZED terms a curator adopted (v0.9 convergence): once
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
  # returns exactly `staffing.keys_for(stream)` — including `nil` for an
  # unconstrained stream — so the path stays byte-identical to v0.3/v0.8.
  module Vocabulary
    module_function

    DEFAULT_DESCRIPTION = "Approved vocabulary term."

    # @return [Hash{String=>String}, nil] effective {term => description}, or nil
    #   when the stream is unconstrained (open terms) and has no authorized terms.
    def for(stream)
      code = Enliterator.staffing.keys_for(stream)            # Hash or nil
      return code unless Enliterator.configuration.apply_approved_keys

      ext = approved_extension(stream)
      return code if ext.empty?

      merged = (code || {}).dup
      ext.each { |term, desc| merged[term] ||= desc }         # code terms win
      merged
    end

    # Terms a curator AUTHORIZED for this stream, with a description (the term's
    # considerer rationale, else a default). {} when none.
    def approved_extension(stream)
      terms = Enliterator::Suggestion.where(stream: stream.to_s, status: "approved").distinct.pluck(:proposed_key)
      return {} if terms.empty?

      descs = Enliterator::ProposedTerm.where(proposed_key: terms).pluck(:proposed_key, :recommended_rationale).to_h
      terms.each_with_object({}) { |t, h| h[t] = descs[t].presence || DEFAULT_DESCRIPTION }
    end
  end
end
