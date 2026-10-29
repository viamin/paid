# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-007
class CreateChatTurnLifecycleEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turn_lifecycle_events, comment: "Append-only audit trail of stall classification, recovery attempts, and outcomes for a chat turn (#4680). Rows are never updated after insert." do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.string :event_name, null: false, comment: "Dotted event name, e.g. chat_turn.stall_detected, chat_turn.recovery_attempted."
      t.references :actor, foreign_key: { to_table: :users }, comment: "The user who triggered the event, when it was human-initiated (e.g. a manual Resume click)."
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false

      t.datetime :created_at, null: false
    end

    add_index :chat_turn_lifecycle_events, [ :chat_turn_id, :occurred_at ]
    add_index :chat_turn_lifecycle_events, :event_name

    enable_tenant_rls
  end

  def down
    drop_table :chat_turn_lifecycle_events, if_exists: true
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_turn_lifecycle_events ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turn_lifecycle_events FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_turn_lifecycle_events
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_turn_lifecycle_events.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_turn_lifecycle_events.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end
end
