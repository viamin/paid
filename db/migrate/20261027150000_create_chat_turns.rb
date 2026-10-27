# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery ledger for an interactive chat turn." do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }, index: false
      t.string :status, null: false, default: "pending", comment: "pending, streaming, completed, failed, stalled, or abandoned"
      t.string :classification, comment: "Terminal or stalled classification, never inferred from client streaming state"
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :completed_at
      t.datetime :recovery_requested_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, [ :chat_session_id, :status ]

    create_table :chat_turn_events, comment: "Queryable audit events for chat turn detection and recovery." do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.string :event_type, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turn_events, [ :chat_turn_id, :created_at ]
    add_index :chat_turn_events, :event_type
  end
end
