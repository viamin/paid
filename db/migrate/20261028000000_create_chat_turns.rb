# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.uuid :external_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :status, null: false, default: "pending"
      t.text :content, null: false
      t.string :stream_message_id
      t.datetime :started_at, null: false
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :stalled_at
      t.string :stall_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.boolean :side_effecting_tool_completed, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :external_id, unique: true
    add_index :chat_turns, [ :chat_session_id, :status, :last_activity_at ], name: "idx_chat_turns_detection"
    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true,
      where: "stream_message_id IS NOT NULL", name: "idx_chat_turns_stream_message"
  end
end
