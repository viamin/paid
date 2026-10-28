# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :stream_id, null: false
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle: pending, streaming, completed, failed, stalled, or abandoned."
      t.datetime :last_activity_at
      t.datetime :detected_at
      t.datetime :completed_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0

      t.timestamps
    end

    add_index :chat_turns, :stream_id, unique: true
    add_index :chat_turns, [ :state, :last_activity_at ]
  end
end
