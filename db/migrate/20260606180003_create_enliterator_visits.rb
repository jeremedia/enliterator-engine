# enliterator_visits — PROV Activity; the compounding spine; immutable history.
class CreateEnliteratorVisits < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_visits do |t|
      t.string :tendable_type, null: false
      t.string :tendable_id, null: false
      t.string :stream, null: false
      t.string :status, null: false, default: "pending" # pending/running/succeeded/failed
      t.string :model
      t.string :prompt_version
      t.jsonb :input_refs, default: {}          # {prior_visit_ids:[], neighbor_ids:[], claim_keys:[]}
      t.jsonb :raw_response, default: {}
      t.jsonb :reconciliation, default: {}       # {added:[], updated:[], deleted:[], noop:[]}
      t.float :confidence
      t.jsonb :tokens, default: {}
      t.integer :duration_ms
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :enliterator_visits,
              [ :tendable_type, :tendable_id, :stream ],
              name: "idx_enliterator_visits_on_tendable_and_stream"

    add_index :enliterator_visits,
              [ :tendable_type, :tendable_id, :created_at ],
              name: "idx_enliterator_visits_on_tendable_and_created_at"
  end
end
