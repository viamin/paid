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

      deduplicate_unstarted_drafts
    end

    add_unstarted_draft_index
  end

  def down
    remove_index :chat_sessions,
      name: "index_chat_sessions_one_unstarted_untitled_personal",
      algorithm: :concurrently
    remove_column :chat_sessions, :started_at
  end

  private

  def add_unstarted_draft_index
    add_index :chat_sessions, :created_by_id, **unstarted_draft_index_options
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.cause.is_a?(PG::UniqueViolation)

    safety_assured { deduplicate_unstarted_drafts }
    remove_index :chat_sessions, name: unstarted_draft_index_options[:name], algorithm: :concurrently if index_exists?(:chat_sessions, name: unstarted_draft_index_options[:name])
    add_index :chat_sessions, :created_by_id, **unstarted_draft_index_options
  end

  def unstarted_draft_index_options
    {
      unique: true,
      where: "started_at IS NULL AND NULLIF(BTRIM(title), '') IS NULL AND inbox_item_key IS NULL AND clarifying_question_issue_id IS NULL AND feature_intent_id IS NULL AND status <> 'archived'",
      name: "index_chat_sessions_one_unstarted_untitled_personal",
      algorithm: :concurrently
    }
  end

  def deduplicate_unstarted_drafts
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
end
