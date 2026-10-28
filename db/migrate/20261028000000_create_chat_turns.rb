# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :stream_message_id
      t.string :status, null: false, default: "pending"
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :stalled_at
      t.datetime :completed_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true, where: "stream_message_id IS NOT NULL"
  end
end
