# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }, comment: "The request that started this turn"
      t.string :stream_message_id, null: false, comment: "Idempotency key shared by streaming transports and job retries"
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle state for this execution attempt"
      t.datetime :last_activity_at, null: false, comment: "Last persisted turn activity used by the stall detector"
      t.datetime :detected_stalled_at, comment: "When the detector classified this turn as stalled"
      t.datetime :completed_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true
    add_index :chat_turns, [ :state, :last_activity_at ]
  end
end
