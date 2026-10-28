class CreateChatTurnRecoveryAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turn_recovery_attempts do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: {to_table: :users}
      t.boolean :automatic, null: false, default: false
      t.integer :requested_revision, null: false
      t.string :status, null: false, default: "queued"
      t.string :outcome
      t.string :deduplication_key
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps

      t.index [:chat_turn_id, :requested_revision], unique: true, name: "idx_chat_turn_recovery_revision"
      t.index [:status, :created_at]
    end

    add_check_constraint :chat_turn_recovery_attempts,
      "status IN ('queued', 'running', 'completed', 'failed')",
      name: "chat_turn_recovery_attempts_status"
  end
end
