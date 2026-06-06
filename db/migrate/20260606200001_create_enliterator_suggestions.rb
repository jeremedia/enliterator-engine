# enliterator_suggestions — governed suggestion sink (SPEC.md > v0.3 > §3).
# A sanctioned channel for the model to propose claim keys no contract covers,
# instead of freelancing key drift. The ontology itself becomes a tended, governed thing.
class CreateEnliteratorSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_suggestions do |t|
      t.string :tendable_type
      t.string :tendable_id
      t.string :stream                       # the stream the tend was on
      t.string :proposed_key                 # the key the model wants to add
      t.text :rationale                      # why it's worth asserting
      t.jsonb :example_value, default: {}    # an illustrative payload
      t.string :tier                         # final tier that produced the suggestion
      t.string :model                        # model id that produced it
      t.bigint :visit_id                     # prov: the visit that surfaced it
      t.string :status, null: false, default: "pending" # pending/approved/mapped/rejected
      t.text :review_note
      t.timestamps
    end

    add_index :enliterator_suggestions, [ :proposed_key, :status ],
              name: "idx_enliterator_suggestions_on_key_and_status"

    add_index :enliterator_suggestions, [ :stream, :status ],
              name: "idx_enliterator_suggestions_on_stream_and_status"

    add_index :enliterator_suggestions, [ :tendable_type, :tendable_id ],
              name: "idx_enliterator_suggestions_on_tendable"
  end
end
