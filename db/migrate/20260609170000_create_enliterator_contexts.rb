# v0.13: nested enliterated collections. A Context is a faceted lens; the tree
# is ancestry (materialized path). `key` is the slug the staffing policy's
# `context "key" do` blocks join on. ROOT RULE: a root Context row anchors the
# tree for UI/membership only — claims/visits at root carry context_id NULL.
class CreateEnliteratorContexts < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_contexts do |t|
      t.string :key,  null: false   # policy join key (lowercase slug)
      t.string :name, null: false
      t.text   :description
      t.string :ancestry            # materialized path (ancestry gem); NULL = root

      t.timestamps
    end

    add_index :enliterator_contexts, :key, unique: true
    add_index :enliterator_contexts, :ancestry
  end
end
