class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: {to_table: :chat_messages}, index: {unique: true}
      t.string :stream_key, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :last_activity_at, null: false
      t.datetime :lease_expires_at
      t.string :pause_reason
      t.string :failure_classification
      t.datetime :detected_stalled_at
      t.references :last_checkpoint_message, foreign_key: {to_table: :chat_messages}
      t.boolean :side_effects_completed, null: false, default: false
      t.integer :revision, null: false, default: 1
      t.integer :recovery_attempts_count, null: false, default: 0
      t.integer :duplicate_prevention_count, null: false, default: 0
      t.string :recovery_outcome

      t.timestamps

      t.index :stream_key, unique: true
      t.index [:state, :last_activity_at]
      t.index :failure_classification
      t.index :detected_stalled_at
    end

    add_check_constraint :chat_turns,
      "state IN ('pending', 'streaming', 'completed', 'failed', 'stalled', 'abandoned')",
      name: "chat_turns_state"
    add_check_constraint :chat_turns, "revision > 0", name: "chat_turns_positive_revision"
  end
end
