# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 @spec CHAT-TURN-RECOVERY-013
class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: { on_delete: :cascade }
      # The user message that opened the turn. Deliberately not a foreign key:
      # ChatSessions::FallbackLoop#discard_partial_attempt deletes the rows a
      # failed attempt persisted, and a foreign key would abort that cleanup.
      t.bigint :user_message_id, null: false
      t.string :state, null: false, default: "pending",
        comment: "Turn lifecycle: pending, streaming, completed, failed, stalled, or abandoned"
      t.string :classification,
        comment: "Why the turn ended or stopped: pending_confirmation, long_running_operation, budget_exhausted, provider_timeout, client_disconnect, infrastructure_failure, or ambiguous_model_stop"
      t.datetime :last_activity_at, null: false, comment: "Last durable activity observed for this turn"
      t.datetime :detected_at, comment: "When the turn was classified as stalled or abandoned"
      t.datetime :completed_at, comment: "When the turn reached a terminal outcome"
      t.datetime :client_disconnected_at, comment: "When the browser subscription for this turn went away"
      t.string :recovery_state, null: false, default: "idle",
        comment: "Recovery lifecycle: idle, requested, running, completed, failed, or denied"
      t.datetime :recovery_requested_at
      t.datetime :recovery_completed_at
      t.integer :recovery_attempts, null: false, default: 0
      t.integer :revision, null: false, default: 0,
        comment: "Incremented on every state change so recovery requests can detect a stale view"
      t.boolean :side_effecting_tools_completed, null: false, default: false,
        comment: "Whether a write tool completed inside this turn, which forbids blind replay"
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, [ :state, :last_activity_at ]
    add_index :chat_turns, [ :chat_session_id, :id ]

    create_table :chat_turn_events do |t|
      t.references :chat_turn, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false,
        comment: "classified, recovery_requested, recovery_started, recovery_completed, recovery_failed, duplicate_prevented, or user_action"
      t.string :outcome
      t.bigint :actor_id, comment: "User who requested the recorded action, when a human made it"
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turn_events, [ :event_type, :created_at ]

    # PostgreSQL RLS has no Rails migration helper. Chat turns are session-owned
    # evidence and must use the same account boundary as chat_messages.
    safety_assured do
      execute "ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON chat_turns
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM chat_sessions
          WHERE chat_sessions.id = chat_turns.chat_session_id
            AND chat_sessions.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM chat_sessions
          WHERE chat_sessions.id = chat_turns.chat_session_id
            AND chat_sessions.account_id = paid_current_account_id()
        ))
      SQL

      execute "ALTER TABLE chat_turn_events ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turn_events FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON chat_turn_events
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM chat_turns
          JOIN chat_sessions ON chat_sessions.id = chat_turns.chat_session_id
          WHERE chat_turns.id = chat_turn_events.chat_turn_id
            AND chat_sessions.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM chat_turns
          JOIN chat_sessions ON chat_sessions.id = chat_turns.chat_session_id
          WHERE chat_turns.id = chat_turn_events.chat_turn_id
            AND chat_sessions.account_id = paid_current_account_id()
        ))
      SQL
    end
  end
end
