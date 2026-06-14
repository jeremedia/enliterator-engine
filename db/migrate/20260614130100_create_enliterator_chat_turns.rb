# v0.39: one retained turn. `events` (jsonb) is the full ordered Loop event stream
# — the artifact (live transport, replay source, v2 tending input). The rest is
# denormalized for query/display. persona_id links the v0.37 persona version that
# produced the turn.
class CreateEnliteratorChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_chat_turns do |t|
      t.references :conversation, null: false,
                   foreign_key: { to_table: :enliterator_chat_conversations }
      t.integer :ordinal,   null: false
      t.text    :question,  null: false
      t.jsonb   :events,    null: false, default: []
      t.text    :answer
      t.string  :desk_name
      t.bigint  :persona_id
      t.integer :elapsed_ms
      t.boolean :budget_hit, null: false, default: false
      t.timestamps
    end
    add_index :enliterator_chat_turns, [ :conversation_id, :ordinal ], unique: true
    add_index :enliterator_chat_turns, :persona_id
  end
end
