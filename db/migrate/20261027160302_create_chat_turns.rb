class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery state for one chat request." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :initiating_message, null: false, index: false, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending", comment: "pending, streaming, completed, failed, stalled, or abandoned"
      t.datetime :last_activity_at, null: false, comment: "Most recent durable turn checkpoint or heartbeat."
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :stalled_at
      t.datetime :recovery_started_at
      t.integer :recovery_attempts_count, null: false, default: 0
      t.string :failure_classification, comment: "Infrastructure classifications may opt into bounded automatic recovery."
      t.boolean :side_effecting_tools_completed, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :chat_turns, [ :status, :last_activity_at ], name: "index_chat_turns_for_stall_detection"
    add_index :chat_turns, :initiating_message_id, unique: true

    create_table :chat_turn_events, comment: "Append-only audit events for chat-turn lifecycle and recovery decisions." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat_turn, null: false, foreign_key: true
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :chat_turn_events, [ :account_id, :event_type, :occurred_at ], name: "index_chat_turn_events_queryable"

    safety_assured do
      %w[chat_turns chat_turn_events].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
        execute <<~SQL
          CREATE POLICY tenant_isolation ON #{table}
            AS PERMISSIVE FOR ALL
            USING (paid_tenant_bypass() OR #{table}.account_id = paid_current_account_id())
            WITH CHECK (paid_tenant_bypass() OR #{table}.account_id = paid_current_account_id())
        SQL
      end
    end
  end
end
