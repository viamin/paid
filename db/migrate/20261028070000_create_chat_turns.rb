# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, foreign_key: { to_table: :chat_messages }
      t.string :stream_message_id, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :checkpointed_at, null: false
      t.datetime :terminal_at
      t.datetime :classified_at
      t.string :failure_classification
      t.integer :recovery_attempts, null: false, default: 0
      t.timestamps
    end

    add_index :chat_turns, :stream_message_id, unique: true
    add_index :chat_turns, [ :state, :checkpointed_at ]
    add_check_constraint :chat_turns,
      "state IN ('pending', 'streaming', 'completed', 'failed', 'stalled', 'abandoned')",
      name: "chat_turns_state"

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
