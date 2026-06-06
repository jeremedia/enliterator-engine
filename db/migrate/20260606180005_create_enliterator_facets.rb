# enliterator_facets — weighted-signal quality scorer (HSDL RecordQuality pattern; SPEC.md > Schema).
class CreateEnliteratorFacets < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_facets do |t|
      t.string :tendable_type, null: false
      t.string :tendable_id, null: false
      t.string :name, null: false
      t.float :score
      t.jsonb :signals, default: {}              # {signal_key => {value:, weight:}}
      t.datetime :computed_at
      t.timestamps
    end

    add_index :enliterator_facets,
              [ :tendable_type, :tendable_id, :name ],
              unique: true,
              name: "idx_enliterator_facets_on_tendable_and_name"
  end
end
