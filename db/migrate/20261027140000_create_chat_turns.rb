# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiating_message, null: false, index: { unique: true }, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.string :classification
      t.datetime :activity_at, null: false
      t.datetime :stalled_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :status, :activity_at ]
  end
end
