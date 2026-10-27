# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiating_message, null: false, index: false, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.datetime :activity_at, null: false
      t.datetime :detected_at
      t.datetime :completed_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :initiating_message_id, unique: true
    add_index :chat_turns, %i[account_id status activity_at]
    add_index :chat_turns, %i[status activity_at]
  end
end
