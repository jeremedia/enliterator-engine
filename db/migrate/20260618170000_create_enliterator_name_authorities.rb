# v0.45: name authority control — the value-side parallel to the self-governing
# key vocabulary. One row per canonical person-name (an authority record):
# `canonical` is the preferred form, `variants` the see-from spellings that
# resolve to it. Read-time only — raw claims are never rewritten; surfaces resolve
# a name VALUE through this table. Empty table ⇒ resolution is the identity ⇒
# byte-identical. context_id is nullable (NULL = root) and scoped up the path.
class CreateEnliteratorNameAuthorities < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_name_authorities do |t|
      t.string  :canonical, null: false
      t.jsonb   :variants,  null: false, default: []
      t.string  :kind,      null: false, default: "person"
      t.bigint  :context_id # NULL = root scope
      t.string  :status,    null: false, default: "auto" # auto | held | ratified
      t.timestamps
    end
    add_index :enliterator_name_authorities, [ :context_id, :kind ]
    add_index :enliterator_name_authorities, [ :canonical, :context_id, :kind ],
              unique: true, name: "idx_enliterator_name_authorities_canonical"
    add_index :enliterator_name_authorities, :variants, using: :gin
  end
end
