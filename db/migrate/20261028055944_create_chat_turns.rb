# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.string :failure_classification
      t.datetime :started_at, null: false
      t.datetime :last_activity_at, null: false
      t.datetime :terminal_at
      t.datetime :stalled_at
      t.datetime :recovery_requested_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, :stalled_at
  end
end
