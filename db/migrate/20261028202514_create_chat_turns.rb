# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 @spec CHAT-TURN-RECOVERY-002
class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turns, comment: "Durable lifecycle tracking for one chat turn (#4680), from the triggering user message to a terminal outcome or stall." do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }, index: { unique: true }
      t.string :status, null: false, default: "pending", comment: "pending, streaming, completed, failed, stalled, or abandoned."
      t.string :failure_classification, comment: "Set when status is failed: rate_limited, provider_error, budget_exhausted, validation_error, unsupported_configuration, or unexpected_error."
      t.boolean :write_tool_dispatched, null: false, default: false, comment: "True once any write tool call has been persisted for this turn; gates eligibility for automatic (unconfirmed) recovery."
      t.integer :recovery_attempts, null: false, default: 0
      t.datetime :recovery_locked_at
      t.datetime :started_at, null: false
      t.datetime :last_activity_at, null: false, comment: "Last durable checkpoint (a persisted message), not raw streaming chunks."
      t.datetime :stall_detected_at
      t.datetime :completed_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]

    enable_tenant_rls
  end

  def down
    drop_table :chat_turns, if_exists: true
  end

  private

  # RLS is the documented exception to the Rails-helper rule: tenancy is keyed
  # through chat_sessions (chat_turns has no direct account_id), mirroring the
  # chat_messages policy from EnableRlsOnChatTables.
  def enable_tenant_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_turns
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_turns.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_turns.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end
end
