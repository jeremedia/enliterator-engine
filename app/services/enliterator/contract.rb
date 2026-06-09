module Enliterator
  # The EFFECTIVE contract for a stream — the controlled vocabulary the model
  # actually sees. It is the CODE contract (the staffing policy's `keys_for`) plus
  # any APPROVED keys a curator adopted (v0.9 convergence): once approved, a key
  # joins the contract so the model emits it as a claim instead of re-proposing it.
  #
  # The approved extension is DERIVED from approval verdicts (approved Suggestions),
  # so it's auditable and dumpable — and the review UI still surfaces the code diff,
  # so an approved key can be codified into the policy permanently (after which the
  # DB derivation is redundant). Code-defined keys always win on a name conflict.
  #
  # When nothing is approved (or `apply_approved_keys` is false), `Contract.for`
  # returns exactly `staffing.keys_for(stream)` — including `nil` for an
  # unconstrained stream — so the contract path stays byte-identical to v0.3/v0.8.
  module Contract
    module_function

    DEFAULT_DESCRIPTION = "Approved vocabulary term."

    # @return [Hash{String=>String}, nil] effective {key => description}, or nil
    #   when the stream is unconstrained and has no approved keys.
    def for(stream)
      code = Enliterator.staffing.keys_for(stream)            # Hash or nil
      return code unless Enliterator.configuration.apply_approved_keys

      ext = approved_extension(stream)
      return code if ext.empty?

      merged = (code || {}).dup
      ext.each { |k, desc| merged[k] ||= desc }               # code keys win
      merged
    end

    # Keys a curator APPROVED for this stream, with a description (the term's
    # considerer rationale, else a default). {} when none.
    def approved_extension(stream)
      keys = Enliterator::Suggestion.where(stream: stream.to_s, status: "approved").distinct.pluck(:proposed_key)
      return {} if keys.empty?

      descs = Enliterator::ProposedTerm.where(proposed_key: keys).pluck(:proposed_key, :recommended_rationale).to_h
      keys.each_with_object({}) { |k, h| h[k] = descs[k].presence || DEFAULT_DESCRIPTION }
    end
  end
end
