# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true, index: false
      t.references :user_message, foreign_key: { to_table: :chat_messages }, index: false, comment: "The persisted user message that initiated this turn."
      t.string :status, null: false, default: "pending", comment: "Durable turn lifecycle state."
      t.string :stream_message_id, null: false, comment: "Client stream identity used to deduplicate one turn."
      t.datetime :last_activity_at, null: false, comment: "Most recent durable message or lifecycle activity."
      t.datetime :stalled_at
      t.datetime :completed_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true, algorithm: :concurrently
    add_index :chat_turns, [ :status, :last_activity_at ], algorithm: :concurrently
  end
end
