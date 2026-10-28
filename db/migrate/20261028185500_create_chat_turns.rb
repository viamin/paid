# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :chat_turns, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }, index: false
      t.string :status, null: false, default: "pending", comment: "Durable lifecycle state for this user-initiated chat turn"
      t.datetime :activity_at, null: false, comment: "Last durable turn activity; used by stall detection"
      t.datetime :detection_at
      t.string :failure_classification
      t.string :recovery_state, null: false, default: "none"
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_turns, :user_message_id, unique: true, algorithm: :concurrently, if_not_exists: true
    add_index :chat_turns, [ :status, :activity_at ], algorithm: :concurrently, if_not_exists: true

    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY;
        DROP POLICY IF EXISTS tenant_isolation ON chat_turns;
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
    execute "DROP POLICY IF EXISTS tenant_isolation ON chat_turns"
    drop_table :chat_turns
  end
end
