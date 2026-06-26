# enliterator_claims — PROV Entity; a provenanced, reconcilable unit of understanding.
class CreateEnliteratorClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_claims do |t|
      t.string :tendable_type, null: false
      t.string :tendable_id, null: false
      t.string :key, null: false                 # e.g. "summary", "authored_by"
      t.jsonb :value                             # string/array/object payload
      t.float :confidence
      t.string :status, null: false, default: "draft"          # draft/verified/superseded
      t.boolean :locked, null: false, default: false           # curator anchor; never auto-superseded
      t.string :review_state, null: false, default: "pending"  # pending/approved/rejected
      t.bigint :visit_id                         # prov:wasGeneratedBy (FK enliterator_visits, nullable)
      t.jsonb :derived_from, default: []         # prov:wasDerivedFrom: [{type:"claim"|"source", id:...}]
      t.string :attributed_to                    # prov:wasAttributedTo: agent (model id / expert)
      t.bigint :superseded_by_id                 # self FK, nullable
      t.timestamps
    end

    add_index :enliterator_claims,
              [ :tendable_type, :tendable_id, :key ],
              name: "idx_enliterator_claims_on_tendable_and_key"

    add_index :enliterator_claims, :superseded_by_id,
              name: "idx_enliterator_claims_on_superseded_by_id"

    add_foreign_key :enliterator_claims, :enliterator_visits, column: :visit_id, on_delete: :nullify
    add_foreign_key :enliterator_claims, :enliterator_claims, column: :superseded_by_id, on_delete: :nullify
  end
end
