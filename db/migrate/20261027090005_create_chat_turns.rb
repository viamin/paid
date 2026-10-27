# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, index: false, foreign_key: { to_table: :chat_messages }
      t.uuid :stream_message_id
      t.string :state, null: false, default: "pending"
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :stalled_at
      t.datetime :recovery_requested_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, [ :state, :last_activity_at ]
  end
end
