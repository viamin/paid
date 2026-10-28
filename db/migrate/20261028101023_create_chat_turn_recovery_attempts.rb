# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-006 CHAT-TURN-RECOVERY-007
class CreateChatTurnRecoveryAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turn_recovery_attempts, comment: "Auditable and deduplicated requests to recover stalled chat turns." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_turn, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: {to_table: :users}
      t.integer :source_revision, null: false
      t.string :status, null: false, default: "queued"
      t.string :outcome
      t.integer :duplicate_prevention_count, null: false, default: 0
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :chat_turn_recovery_attempts, [:chat_turn_id, :source_revision],
      unique: true, name: "index_chat_turn_recoveries_on_turn_and_revision"

    safety_assured do
      execute "ALTER TABLE chat_turn_recovery_attempts ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turn_recovery_attempts FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON chat_turn_recovery_attempts
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
      SQL
    end
  end
end
