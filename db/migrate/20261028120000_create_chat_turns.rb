# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }, index: { unique: true }
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle state for the user-originated chat turn."
      t.string :failure_classification, comment: "Structural reason a terminal turn stopped without completing."
      t.datetime :last_activity_at, null: false, comment: "Most recent persisted evidence for this turn."
      t.datetime :detected_stalled_at, comment: "When the server classified the turn as stalled."
      t.datetime :completed_at, comment: "When the turn reached a terminal successful outcome."
      t.timestamps
    end

    add_index :chat_turns, [ :state, :last_activity_at ], name: "index_chat_turns_on_state_and_last_activity_at"
  end
end
