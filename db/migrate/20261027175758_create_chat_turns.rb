class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.string :stream_message_id
      t.string :status, null: false, default: "pending"
      t.string :failure_classification
      t.datetime :last_activity_at, null: false
      t.datetime :detected_stalled_at
      t.datetime :completed_at
      t.integer :recovery_attempts, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :chat_turns, :stream_message_id, unique: true, where: "stream_message_id IS NOT NULL"
    add_index :chat_turns, %i[status last_activity_at]
    create_table :chat_turn_events do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :chat_turn_events, %i[chat_turn_id event_type occurred_at]

    reversible do |direction|
      direction.up do
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
      direction.down do
        safety_assured do
          execute "DROP POLICY tenant_isolation ON chat_turn_events"
          execute "DROP POLICY tenant_isolation ON chat_turns"
        end
      end
    end
  end
end
