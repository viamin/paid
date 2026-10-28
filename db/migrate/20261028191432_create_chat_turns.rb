class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle: pending, streaming, completed, failed, stalled, or abandoned."
      t.datetime :activity_at, null: false, comment: "Most recent durable activity for stalled-turn detection."
      t.datetime :completed_at
      t.datetime :stalled_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, [ :state, :activity_at ], name: "index_chat_turns_for_stall_detection"
  end
end
