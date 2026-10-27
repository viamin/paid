# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, index: false, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending", comment: "Durable chat turn lifecycle"
      t.string :classification, comment: "Terminal or stall classification"
      t.datetime :last_activity_at, null: false
      t.datetime :detected_at, comment: "When a stalled turn was classified"
      t.datetime :completed_at, comment: "When the turn reached a terminal state"
      t.integer :recovery_attempts, null: false, default: 0
      t.timestamps
    end

    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, :user_message_id, unique: true

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
    end
  end
end
