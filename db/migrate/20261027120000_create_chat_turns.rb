# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, index: false, foreign_key: { to_table: :chat_messages }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "streaming"
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :stalled_at
      t.datetime :completed_at
      t.integer :recovery_attempts, null: false, default: 0
      t.string :recovery_outcome
      t.references :recovery_requested_by, foreign_key: { to_table: :users }
      t.jsonb :checkpoint, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :chat_turns, :user_message_id, unique: true, algorithm: :concurrently
    add_index :chat_turns, [ :status, :last_activity_at ], algorithm: :concurrently

    add_reference :chat_messages, :chat_turn, foreign_key: false, index: { algorithm: :concurrently }

    create_table :chat_turn_events do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :chat_turn_events, [ :event_type, :created_at ], algorithm: :concurrently
  end
end
