# v0.24: the subject-heading index. The catalog's heading aggregation, the
# subject filter, the per-key entity-bearing sampling, and Synopsis.key_summary
# all lead on `key` (optionally narrowed by context) — and no existing index
# leads on key (the two tendable composites lead on tendable_*). Additive.
class AddKeyIndexToEnliteratorClaims < ActiveRecord::Migration[8.1]
  def change
    add_index :enliterator_claims, [ :key, :context_id ],
              name: "idx_enliterator_claims_on_key_and_context"
  end
end
