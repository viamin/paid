# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true, comment: "Conversation that owns this turn"
      t.references :user_message, foreign_key: { to_table: :chat_messages }, comment: "Durable user checkpoint"
      t.references :assistant_message, foreign_key: { to_table: :chat_messages }, comment: "Terminal assistant checkpoint"
      t.string :stream_message_id, null: false, comment: "Transport idempotency key for this turn"
      t.string :state, null: false, default: "pending", comment: "pending, streaming, completed, failed, stalled, or abandoned"
      t.string :failure_classification, comment: "Terminal failure classification when processing cannot complete"
      t.datetime :last_activity_at, null: false, comment: "Most recent durable checkpoint time"
      t.datetime :stalled_at, comment: "When inactivity classification marked this turn stalled"
      t.datetime :completed_at, comment: "When the turn entered a terminal state"
      t.integer :recovery_attempts, null: false, default: 0, comment: "Auditable count of claimed recovery attempts"
      t.timestamps
    end

    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, [ :state, :last_activity_at ]
  end
end
