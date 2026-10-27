# frozen_string_literal: true

# Append-only audit trail for chat turn outcomes: stall classifications,
# recovery attempts and outcomes, user actions, duplicate-prevention
# decisions, and abandonment.
class CreateChatTurnEvents < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:chat_turn_events)

    create_table :chat_turn_events, comment: "Auditable events recorded for a chat turn." do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :actor, null: true, foreign_key: { to_table: :users }
      t.string :event_type, null: false, comment: "stall_detected, recovery_requested, recovery_started, recovery_succeeded, recovery_failed, recovery_declined, duplicate_prevented, turn_abandoned."
      t.string :outcome, comment: "Result of the recorded event."
      t.string :user_action, comment: "auto_recovery, user_resume, none."
      t.boolean :side_effecting_tools_completed, null: false, default: false,
        comment: "Whether a side-effecting tool call had already completed when the event was recorded."
      t.jsonb :metadata, null: false, default: {}, comment: "Non-secret event detail, including the failure classification."

      t.timestamps
    end

    add_index :chat_turn_events, [ :chat_turn_id, :created_at ]
    add_index :chat_turn_events, [ :event_type, :created_at ]

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
