# frozen_string_literal: true

# Durable record of one interactive chat turn: the unit that carries a turn's
# lifecycle from "opened" to a terminal outcome, so a turn that never reached
# one can be detected, explained, and recovered.
class CreateChatTurns < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:chat_turns)

    create_table :chat_turns, comment: "Durable lifecycle record for one interactive chat turn." do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: true, foreign_key: { to_table: :chat_messages }
      t.string :status, null: false, default: "pending", comment: "Turn lifecycle: pending, streaming, completed, failed, stalled, abandoned."
      t.string :failure_classification, comment: "Why the turn stopped abnormally, when it did."
      t.string :recovery_state, null: false, default: "none", comment: "Recovery lifecycle: none, in_progress, succeeded, failed."
      t.integer :recovery_attempts, null: false, default: 0, comment: "Recovery attempts claimed for this turn."
      t.integer :revision, null: false, default: 0, comment: "Bumped on every write; a resume request carries the revision it saw."
      t.datetime :started_at, null: false, comment: "When the turn opened."
      t.datetime :last_activity_at, null: false, comment: "When the turn last wrote durable output."
      t.datetime :finished_at, comment: "When the turn reached a terminal outcome."
      t.datetime :stalled_at, comment: "When the turn was classified as stalled."
      t.datetime :abandoned_at, comment: "When the turn was abandoned."
      t.jsonb :metadata, null: false, default: {}, comment: "Turn-scoped facts: completed tool names, side-effecting completion, awaiting-confirmation flag."

      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :user_message_id ], unique: true,
      name: "index_chat_turns_on_session_and_user_message"
    add_index :chat_turns, [ :status, :last_activity_at ],
      name: "index_chat_turns_on_status_and_last_activity"

    enable_tenant_rls
  end

  def down
    drop_table :chat_turns, if_exists: true
  end

  private

  def enable_tenant_rls
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
