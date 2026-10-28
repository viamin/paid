# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :lifecycle, null: false, default: "pending"
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.string :classification
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :lifecycle, :last_activity_at ]
    add_check_constraint :chat_turns,
      "lifecycle IN ('pending', 'streaming', 'awaiting_confirmation', 'completed', 'failed', 'stalled', 'abandoned')",
      name: "chat_turns_lifecycle"
  end
end
