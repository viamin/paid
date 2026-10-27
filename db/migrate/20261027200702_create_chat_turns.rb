# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }, index: { unique: true }
      t.string :status, null: false, default: "pending", comment: "Durable lifecycle state for the chat turn"
      t.datetime :last_activity_at, null: false, comment: "Most recent durable server-side turn activity"
      t.datetime :completed_at
      t.datetime :stalled_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ], name: "index_chat_turns_for_stall_detection"
  end
end
