# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.string :stream_message_id
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at
      t.datetime :completed_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :stream_message_id, unique: true, where: "stream_message_id IS NOT NULL"
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, :user_message_id, unique: true, name: "index_chat_turns_on_user_message_id_unique"

    create_table :chat_turn_events do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turn_events, [ :chat_turn_id, :created_at ]
    add_index :chat_turn_events, :event_type
  end
end
