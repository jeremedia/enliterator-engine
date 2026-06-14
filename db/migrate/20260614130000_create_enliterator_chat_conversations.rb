# v0.39: a retained chat session (the dev/demo backend's conversations). `token`
# is the client-generated grouping key; turns belong to a conversation in order.
class CreateEnliteratorChatConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :enliterator_chat_conversations do |t|
      t.string :token,  null: false
      t.string :context
      t.string :label
      t.string :source, null: false, default: "live"
      t.timestamps
    end
    add_index :enliterator_chat_conversations, :token, unique: true
  end
end
