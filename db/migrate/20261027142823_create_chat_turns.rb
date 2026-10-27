# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :stream_message_id, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :activity_at, null: false
      t.datetime :detection_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, [ :status, :activity_at ]
  end
end
