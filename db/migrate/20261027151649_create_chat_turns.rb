class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true, index: false
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }, index: false
      t.string :stream_message_id, null: false
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle state for the chat turn."
      t.datetime :last_activity_at, null: false, comment: "Most recent server-side turn activity."
      t.datetime :stalled_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, :chat_session_id
    add_index :chat_turns, [ :state, :last_activity_at ]
  end
end
