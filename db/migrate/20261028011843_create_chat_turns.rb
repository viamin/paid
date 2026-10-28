class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiating_message, foreign_key: { to_table: :chat_messages }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :stream_message_id
      t.string :status, null: false, default: "pending", comment: "Durable chat turn lifecycle state."
      t.string :failure_classification, comment: "Machine-classified terminal failure, when known."
      t.datetime :last_activity_at, null: false, comment: "Most recent durable turn activity."
      t.datetime :completed_at
      t.datetime :stalled_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true,
      where: "stream_message_id IS NOT NULL", name: "index_chat_turns_on_session_and_stream"
    add_index :chat_turns, [ :status, :last_activity_at ], name: "index_chat_turns_for_stall_detection"

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

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON chat_turns"
      execute "ALTER TABLE chat_turns NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE chat_turns DISABLE ROW LEVEL SECURITY"
    end

    drop_table :chat_turns
  end
end
