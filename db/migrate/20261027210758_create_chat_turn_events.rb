# frozen_string_literal: true

# Audit trail for chat turn stalls and recoveries: classification, detection
# time, recovery attempts and outcomes, user actions, and duplicate-prevention
# events.
class CreateChatTurnEvents < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:chat_turn_events)

    create_table :chat_turn_events, comment: "Audit trail for chat turn stalls and recovery attempts." do |t|
      t.references :chat_turn, null: false, foreign_key: { on_delete: :cascade }
      t.references :chat_session, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false,
        comment: "detected, recovery_attempted, recovery_succeeded, recovery_failed, user_action, duplicate_prevented, or abandoned."
      t.string :outcome, comment: "Outcome of the recorded event: succeeded, failed, blocked, or duplicate."
      t.bigint :actor_id, comment: "User who triggered the event, when a human did."
      t.jsonb :metadata, null: false, default: {}, comment: "Non-secret event details."

      t.timestamps
    end

    add_index :chat_turn_events, [ :chat_turn_id, :created_at ]
    add_index :chat_turn_events, [ :event_type, :created_at ]
    add_index :chat_turn_events, [ :chat_session_id, :created_at ]

    enable_tenant_rls
  end

  def down
    drop_table :chat_turn_events, if_exists: true
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_turn_events ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turn_events FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_turn_events
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_turn_events.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_turn_events.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end
end
