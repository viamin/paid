# frozen_string_literal: true

class CreateChatTurnEvents < ActiveRecord::Migration[8.1]
  def change
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
