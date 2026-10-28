# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.string :stream_message_id
      t.string :status, null: false, default: "pending"
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :stalled_at
      t.string :failure_classification
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true,
      where: "stream_message_id IS NOT NULL", name: "index_chat_turns_on_session_and_stream"
    add_index :chat_turns, [ :status, :last_activity_at ]
  end
end
