# frozen_string_literal: true

# Topology (v0.56): a Context can be DERIVED from a host whole (one Context per
# Manuscript, say) by Topology::Sync. derived_from_* records which whole owns it —
# strings, like context_memberships' member columns, because host PKs may be uuid.
# nil = hand-curated (every pre-v0.56 row): sync never touches those. Partial
# unique index: one derived context per whole; the all-nil hand-curated rows are
# exempt by the WHERE clause (intent stated in the index itself).
class AddDerivedFromToEnliteratorContexts < ActiveRecord::Migration[7.1]
  def change
    add_column :enliterator_contexts, :derived_from_type, :string
    add_column :enliterator_contexts, :derived_from_id, :string

    add_index :enliterator_contexts, [ :derived_from_type, :derived_from_id ],
              unique: true,
              where: "derived_from_type IS NOT NULL",
              name: "idx_enliterator_contexts_derived_from"
  end
end
