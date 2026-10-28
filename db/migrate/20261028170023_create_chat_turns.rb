# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turns, comment: "Durable lifecycle and recovery state for each chat turn" do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, index: false, foreign_key: { to_table: :chat_messages }
      t.string :state, null: false, default: "pending", comment: "Durable lifecycle state for one user-initiated chat turn"
      t.datetime :last_activity_at, null: false, comment: "Most recent persisted evidence for stall detection"
      t.datetime :stalled_at, comment: "When the server classified this turn as stalled"
      t.datetime :completed_at, comment: "When a terminal assistant response was persisted"
      t.string :failure_classification, comment: "Mechanical failure classification; never model-inferred"
      t.integer :recovery_attempts, null: false, default: 0
      t.timestamps
    end

    add_index :chat_turns, [ :state, :last_activity_at ], name: "index_chat_turns_for_stall_detection"
    add_index :chat_turns, :user_message_id, unique: true

    create_table :chat_turn_events, comment: "Auditable lifecycle and recovery events for chat turns" do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turn_events, [ :chat_turn_id, :event_type, :created_at ], name: "index_chat_turn_events_audit"

    enable_tenant_rls
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON chat_turn_events"
      execute "DROP POLICY IF EXISTS tenant_isolation ON chat_turns"
      execute "ALTER TABLE chat_turn_events DISABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turns DISABLE ROW LEVEL SECURITY"
    end
    drop_table :chat_turn_events
    drop_table :chat_turns
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY;
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
          ));

        ALTER TABLE chat_turn_events ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turn_events FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_turn_events
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM chat_turns
            INNER JOIN chat_sessions ON chat_sessions.id = chat_turns.chat_session_id
            WHERE chat_turns.id = chat_turn_events.chat_turn_id
              AND chat_sessions.account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM chat_turns
            INNER JOIN chat_sessions ON chat_sessions.id = chat_turns.chat_session_id
            WHERE chat_turns.id = chat_turn_events.chat_turn_id
              AND chat_sessions.account_id = paid_current_account_id()
          ));
      SQL
    end
  end
end
