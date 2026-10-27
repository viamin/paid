# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.string :stream_message_id, null: false
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :completed_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.datetime :recovery_started_at
      t.string :recovery_token
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ], name: "index_chat_turns_for_stall_detection"
    add_index :chat_turns, :stream_message_id, unique: true
    add_check_constraint :chat_turns,
      "status IN ('pending', 'streaming', 'awaiting_confirmation', 'completed', 'failed', 'stalled', 'abandoned')",
      name: "chat_turns_valid_status"
    add_check_constraint :chat_turns, "recovery_attempts >= 0", name: "chat_turns_nonnegative_recovery_attempts"
  end
end
