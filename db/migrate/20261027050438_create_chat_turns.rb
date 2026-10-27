# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.string :stream_message_id
      t.string :status, null: false, default: "pending", comment: "Durable lifecycle: pending, streaming, completed, failed, stalled, or abandoned."
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :detected_stalled_at
      t.datetime :completed_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :stream_message_id, unique: true, where: "stream_message_id IS NOT NULL"
    add_index :chat_turns, [ :status, :last_activity_at ]
  end
end
