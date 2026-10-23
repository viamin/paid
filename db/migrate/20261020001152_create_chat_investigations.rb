# frozen_string_literal: true

# Durable, reconnectable work attached to one question in a shared chat.
class CreateChatInvestigations < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:chat_investigations)

    create_table :chat_investigations, comment: "Bounded research or isolated experiment work requested from a chat question." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.references :clarifying_question_progress, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :kind, null: false, comment: "Investigation mode: research or experiment."
      t.string :status, null: false, default: "queued", comment: "Lifecycle state, including authorization and cancellation outcomes."
      t.text :prompt, null: false, comment: "Question-scoped request, never executable application-origin HTML."
      t.integer :estimated_cost_cents, null: false, default: 0, comment: "Maximum cost checked before dispatch."
      t.integer :reserved_cost_cents, null: false, default: 0, comment: "Budget held while this investigation is active."
      t.text :result, comment: "Reconnectable textual result or failure explanation."
      t.jsonb :metadata, null: false, default: {}, comment: "Non-secret progress and isolated runtime metadata."
      t.datetime :started_at, comment: "When durable execution began."
      t.datetime :finished_at, comment: "When the investigation reached a terminal state."
      t.datetime :cancelled_at, comment: "When a collaborator cancelled the investigation."

      t.timestamps
    end

    add_index :chat_investigations, [ :project_id, :status ]
    add_index :chat_investigations, [ :clarifying_question_progress_id, :created_at ]

    enable_tenant_rls
  end

  def down
    drop_table :chat_investigations, if_exists: true
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_investigations ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_investigations FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_investigations
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              chat_investigations.account_id = paid_current_account_id()
              AND EXISTS (SELECT 1 FROM projects WHERE projects.id = chat_investigations.project_id AND projects.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM chat_sessions WHERE chat_sessions.id = chat_investigations.chat_session_id AND chat_sessions.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM clarifying_question_progresses WHERE clarifying_question_progresses.id = chat_investigations.clarifying_question_progress_id AND clarifying_question_progresses.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM users WHERE users.id = chat_investigations.created_by_id AND users.account_id = paid_current_account_id())
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              chat_investigations.account_id = paid_current_account_id()
              AND EXISTS (SELECT 1 FROM projects WHERE projects.id = chat_investigations.project_id AND projects.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM chat_sessions WHERE chat_sessions.id = chat_investigations.chat_session_id AND chat_sessions.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM clarifying_question_progresses WHERE clarifying_question_progresses.id = chat_investigations.clarifying_question_progress_id AND clarifying_question_progresses.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM users WHERE users.id = chat_investigations.created_by_id AND users.account_id = paid_current_account_id())
            )
          );
      SQL
    end
  end
end
