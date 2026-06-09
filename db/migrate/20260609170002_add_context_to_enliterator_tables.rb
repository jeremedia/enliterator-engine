# v0.13: context-scope Claims, Visits, and Suggestions. NULLABLE by design —
# NULL is the root scope (root rule), which is exactly where all pre-v0.13 rows
# already live, so no backfill is needed for back-compat. Composite indexes
# match the hot queries: reconcile (claims by tendable+context+key) and the
# per-context tending/health lookups (visits by tendable+context+facet).
class AddContextToEnliteratorTables < ActiveRecord::Migration[8.1]
  def change
    add_reference :enliterator_claims, :context,
                  null: true, foreign_key: { to_table: :enliterator_contexts }
    add_reference :enliterator_visits, :context,
                  null: true, foreign_key: { to_table: :enliterator_contexts }
    add_reference :enliterator_suggestions, :context,
                  null: true, foreign_key: { to_table: :enliterator_contexts }

    add_index :enliterator_claims,
              [ :tendable_type, :tendable_id, :context_id, :key ],
              name: "idx_enliterator_claims_on_tendable_context_key"
    add_index :enliterator_visits,
              [ :tendable_type, :tendable_id, :context_id, :facet ],
              name: "idx_enliterator_visits_on_tendable_context_facet"
  end
end
