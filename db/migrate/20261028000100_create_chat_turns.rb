# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle: pending, streaming, completed, failed, stalled, or abandoned."
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :terminal_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, %i[state last_activity_at], name: "index_chat_turns_for_stall_detection"
  end
end
