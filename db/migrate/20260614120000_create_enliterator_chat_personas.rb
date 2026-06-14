# v0.37: per-desk persona versions (append-only). The effective persona for a
# desk is its latest row; rollback inserts a new row copying an older version.
class CreateEnliteratorChatPersonas < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_chat_personas do |t|
      t.string :desk_name,     null: false
      t.text   :system_prompt, null: false
      t.string :editor          # who (host-supplied; nil in dev)
      t.string :note            # optional change/rollback note
      t.timestamps
    end
    add_index :enliterator_chat_personas, [ :desk_name, :created_at ]
  end
end
