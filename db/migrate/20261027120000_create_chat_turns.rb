# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiating_message, null: false, foreign_key: { to_table: :chat_messages }, index: { unique: true }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :detected_stalled_at
      t.datetime :completed_at
      t.datetime :recovery_requested_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]
  end
end
