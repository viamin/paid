class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending"
      t.string :classification
      t.datetime :activity_at, null: false
      t.datetime :detected_at
      t.datetime :completed_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true
    add_index :chat_turns, %i[status activity_at]

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
      SQL
    end
  end

  def down
    drop_table :chat_turns
  end
end
