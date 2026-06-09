# v0.13: an item's M2M membership in Contexts. member_id is a STRING like every
# polymorphic id in the engine (host PKs may be uuid — HSDL's DocMetum is).
# Root membership is implicit (root rule), so roots need no rows.
class CreateEnliteratorContextMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_context_memberships do |t|
      t.references :context, null: false, foreign_key: { to_table: :enliterator_contexts }
      t.string :member_type, null: false
      t.string :member_id,   null: false

      t.timestamps
    end

    add_index :enliterator_context_memberships,
              [ :context_id, :member_type, :member_id ],
              unique: true,
              name: "idx_enliterator_memberships_uniqueness"
    add_index :enliterator_context_memberships,
              [ :member_type, :member_id ],
              name: "idx_enliterator_memberships_on_member"
  end
end
