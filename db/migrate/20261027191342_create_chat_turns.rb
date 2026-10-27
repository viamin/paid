class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: { on_delete: :cascade }
      t.references :user_message, foreign_key: { to_table: :chat_messages, on_delete: :nullify }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :stream_message_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :stall_classification
      t.datetime :last_activity_at, null: false
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :stalled_at
      t.boolean :side_effecting_tools_completed, null: false, default: false
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, :stalled_at

    add_reference :chat_messages, :chat_turn, foreign_key: { on_delete: :nullify }

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

  def down
    remove_reference :chat_messages, :chat_turn, foreign_key: true
    drop_table :chat_turns
  end
end
