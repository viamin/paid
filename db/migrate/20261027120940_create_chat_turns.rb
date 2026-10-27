# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :stalled_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]
    add_reference :chat_messages, :chat_turn, index: { algorithm: :concurrently }
  end
end
