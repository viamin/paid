# frozen_string_literal: true

class AddStartedAtToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :chat_sessions, :started_at, :datetime,
      if_not_exists: true,
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

      mark_referenced_drafts_started
      deduplicate_unstarted_drafts
    end

    add_unstarted_draft_index
  end

  def down
    if index_exists?(:chat_sessions, name: "index_chat_sessions_one_unstarted_untitled_personal")
      remove_index :chat_sessions,
        name: "index_chat_sessions_one_unstarted_untitled_personal",
        algorithm: :concurrently
    end
    safety_assured { remove_column :chat_sessions, :started_at }
  end

  private

  def add_unstarted_draft_index
    add_index :chat_sessions, :created_by_id, **unstarted_draft_index_options, if_not_exists: true
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
    # Recheck immediately before selecting duplicates. A rolling-deploy writer
    # can attach a dependent record after the initial scan in +up+; that draft
    # is no longer disposable and must be released from the partial index
    # rather than deleted.
    mark_referenced_drafts_started

    discarded_unstarted_drafts.each do |draft|
      ChatSessions::WorkspaceCleanup.call(chat_session: draft)
    end

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

  # An application server from before this migration can attach records after
  # the user-message backfill has run. Preserve those sessions rather than
  # risking an FK violation or deleting work that arrived during deployment.
  def mark_referenced_drafts_started
    execute <<~SQL.squish
      UPDATE chat_sessions
      SET started_at = COALESCE(updated_at, created_at)
      WHERE started_at IS NULL
        AND (
          EXISTS (
            SELECT 1 FROM chat_messages
            WHERE chat_messages.chat_session_id = chat_sessions.id
              AND chat_messages.role = 'user'
          )
          OR EXISTS (SELECT 1 FROM chat_diagrams WHERE chat_diagrams.chat_session_id = chat_sessions.id)
          OR EXISTS (SELECT 1 FROM chat_investigations WHERE chat_investigations.chat_session_id = chat_sessions.id)
          OR EXISTS (SELECT 1 FROM chat_session_projects WHERE chat_session_projects.chat_session_id = chat_sessions.id)
          OR EXISTS (SELECT 1 FROM chat_turn_lifecycle_events WHERE chat_turn_lifecycle_events.chat_session_id = chat_sessions.id)
          OR EXISTS (SELECT 1 FROM chat_turns WHERE chat_turns.chat_session_id = chat_sessions.id)
          OR EXISTS (SELECT 1 FROM clarifying_question_progresses WHERE clarifying_question_progresses.chat_session_id = chat_sessions.id)
        )
    SQL
  end

  def discarded_unstarted_drafts
    ChatSession.find_by_sql(<<~SQL.squish)
      SELECT chat_sessions.*
      FROM chat_sessions
      INNER JOIN (
        SELECT id,
          ROW_NUMBER() OVER (PARTITION BY created_by_id ORDER BY created_at DESC, id DESC) AS position
        FROM chat_sessions
        WHERE started_at IS NULL
          AND NULLIF(BTRIM(title), '') IS NULL
          AND inbox_item_key IS NULL
          AND clarifying_question_issue_id IS NULL
          AND feature_intent_id IS NULL
          AND status <> 'archived'
      ) ranked_drafts ON ranked_drafts.id = chat_sessions.id
      WHERE ranked_drafts.position > 1
    SQL
  end
end
