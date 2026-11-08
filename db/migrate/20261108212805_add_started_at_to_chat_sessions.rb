# frozen_string_literal: true

class AddStartedAtToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :chat_sessions, :started_at, :datetime,
      comment: "When the first user message started this chat session."

    safety_assured do
      execute <<~SQL.squish
        UPDATE chat_sessions
        SET started_at = COALESCE(updated_at, created_at)
        WHERE started_at IS NULL
          AND EXISTS (
            SELECT 1 FROM chat_messages
            WHERE chat_messages.chat_session_id = chat_sessions.id
              AND chat_messages.role = 'user'
          )
      SQL

      execute <<~SQL.squish
        WITH ranked_drafts AS (
          SELECT id,
            ROW_NUMBER() OVER (PARTITION BY created_by_id ORDER BY created_at DESC, id DESC) AS position
          FROM chat_sessions
          WHERE started_at IS NULL
            AND NULLIF(BTRIM(title), '') IS NULL
            AND inbox_item_key IS NULL
            AND clarifying_question_issue_id IS NULL
            AND feature_intent_id IS NULL
            AND status <> 'archived'
        ), discarded_drafts AS (
          SELECT id FROM ranked_drafts WHERE position > 1
        ), deleted_messages AS (
          DELETE FROM chat_messages
          WHERE chat_session_id IN (SELECT id FROM discarded_drafts)
          RETURNING chat_session_id
        )
        DELETE FROM chat_sessions
        WHERE id IN (SELECT id FROM discarded_drafts)
      SQL
    end

    add_index :chat_sessions, :created_by_id,
      unique: true,
      where: "started_at IS NULL AND NULLIF(BTRIM(title), '') IS NULL AND inbox_item_key IS NULL AND clarifying_question_issue_id IS NULL AND feature_intent_id IS NULL AND status <> 'archived'",
      name: "index_chat_sessions_one_unstarted_untitled_personal",
      algorithm: :concurrently
  end

  def down
    remove_index :chat_sessions,
      name: "index_chat_sessions_one_unstarted_untitled_personal",
      algorithm: :concurrently
    remove_column :chat_sessions, :started_at
  end
end
