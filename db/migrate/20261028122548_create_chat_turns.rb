# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery ledger for one chat request" do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.uuid :stream_message_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :terminal_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, :user_message_id, unique: true
  end
end
