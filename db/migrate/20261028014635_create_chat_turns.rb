class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_turns, comment: "Durable lifecycle and recovery state for one accepted chat send." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiated_by, null: false, foreign_key: { to_table: :users }
      t.references :user_message, foreign_key: { to_table: :chat_messages, on_delete: :nullify }
      t.references :notice_message, foreign_key: { to_table: :chat_messages, on_delete: :nullify }
      t.references :recovery_requested_by, foreign_key: { to_table: :users }
      t.string :stream_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :stall_classification
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :lease_expires_at
      t.datetime :stalled_at
      t.datetime :completed_at
      t.datetime :recovery_requested_at
      t.datetime :recovery_finished_at
      t.integer :recovery_attempts, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.boolean :side_effecting_tools_completed, null: false, default: false
      t.boolean :checkpoint_replay_safe, null: false, default: false
      t.jsonb :checkpoint, null: false, default: {}
      t.jsonb :audit_events, null: false, default: []
      t.text :failure_message
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_id ], unique: true
    add_index :chat_turns, [ :status, :last_activity_at ]
    add_index :chat_turns, :stall_classification
    add_index :chat_turns, :audit_events, using: :gin

    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_turns ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_turns FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_turns
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (
            paid_tenant_bypass() OR (
              account_id = paid_current_account_id()
              AND EXISTS (SELECT 1 FROM chat_sessions WHERE chat_sessions.id = chat_turns.chat_session_id AND chat_sessions.account_id = paid_current_account_id())
            )
          );
      SQL
    end
  end

  def down
    drop_table :chat_turns, if_exists: true
  end
end
