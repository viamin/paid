# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiating_message, null: false, foreign_key: true
      t.string :state, null: false, default: "pending"
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :stalled_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
    add_index :chat_turns, [ :state, :last_activity_at ]
  end
end
