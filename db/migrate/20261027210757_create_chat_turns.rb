# frozen_string_literal: true

# Durable lifecycle record for one interactive chat turn: the work between a
# persisted user message and the terminal assistant response that answers it.
class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:chat_turns)

    create_table :chat_turns, comment: "Durable lifecycle record for one interactive chat turn." do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages, on_delete: :nullify },
        comment: "User message that opened the turn."
      t.references :checkpoint_message, foreign_key: { to_table: :chat_messages, on_delete: :nullify },
        comment: "Last durable message the turn produced."
      t.string :status, null: false, default: "pending",
        comment: "Turn lifecycle: pending, streaming, completed, failed, stalled, abandoned."
      t.string :stall_classification,
        comment: "Why the turn was classified as stalled: infrastructure_failure, provider_timeout, budget_exhausted, client_disconnect, or model_stop."
      t.string :failure_class, comment: "Last failure class observed on the turn."
      t.integer :recovery_attempts, null: false, default: 0, comment: "Recovery attempts the turn has consumed."
      t.string :recovery_status, null: false, default: "none",
        comment: "Recovery state: none, in_progress, succeeded, failed."
      t.string :recovery_key, comment: "Idempotency key of the in-flight recovery attempt."
      t.datetime :started_at, null: false, comment: "When the turn opened."
      t.datetime :last_activity_at, null: false, comment: "When the turn last recorded durable activity."
      t.datetime :detected_at, comment: "When the stall was detected."
      t.datetime :stalled_at, comment: "When the turn was marked stalled."
      t.datetime :completed_at, comment: "When the turn reached a terminal outcome."
      t.datetime :abandoned_at, comment: "When the stalled turn was abandoned."
      t.jsonb :metadata, null: false, default: {}, comment: "Non-secret turn signals, e.g. client_disconnect."
      t.integer :lock_version, null: false, default: 0, comment: "Optimistic-locking revision token for recovery requests."

      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :status ]
    add_index :chat_turns, [ :status, :last_activity_at ], name: "index_chat_turns_on_status_and_last_activity_at"
    add_index :chat_turns, [ :chat_session_id, :user_message_id ]

    enable_tenant_rls
  end

  def down
    drop_table :chat_turns, if_exists: true
  end

  private

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
