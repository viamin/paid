# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery record for one chat request." do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.string :stream_message_id, null: false, comment: "Client-visible idempotency key for the transport attempt."
      t.string :status, null: false, default: "pending", comment: "pending, streaming, completed, failed, stalled, or abandoned."
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :stalled_at
      t.datetime :recovery_started_at
      t.integer :recovery_count, null: false, default: 0
      t.string :failure_classification
      t.boolean :side_effecting_tools_completed, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_reference :chat_messages, :chat_turn, foreign_key: true
  end
end
