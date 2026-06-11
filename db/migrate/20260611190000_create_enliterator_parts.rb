# v0.25: PARTS — sections of a host record, as first-class tendables (the
# cataloger's analytical entries). The text is a stored copy of the slice so
# content_digest is stable evidence independent of the parent's re-conversions.
class CreateEnliteratorParts < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_parts do |t|
      t.string  :record_type, null: false
      t.string  :record_id,   null: false
      t.integer :ordinal,     null: false
      t.string  :heading
      t.text    :text
      t.integer :char_start
      t.integer :char_end
      t.string  :content_digest

      t.timestamps
    end

    add_index :enliterator_parts, [ :record_type, :record_id, :ordinal ],
              unique: true, name: "idx_enliterator_parts_identity"
    add_index :enliterator_parts, [ :record_type, :record_id ]
  end
end
