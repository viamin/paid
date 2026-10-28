# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery evidence for an interactive chat turn" do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, index: { unique: true }, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending", comment: "pending, streaming, completed, failed, stalled, or abandoned"
      t.datetime :last_activity_at, null: false, comment: "Last durable turn activity; never a transient browser event"
      t.datetime :detected_at, comment: "When the stall detector classified this turn"
      t.jsonb :metadata, null: false, default: {}, comment: "Classification, recovery, and audit evidence"
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]

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
