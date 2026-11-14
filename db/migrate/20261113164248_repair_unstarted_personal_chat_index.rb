# frozen_string_literal: true

# @spec CHAT-API-030
class RepairUnstartedPersonalChatIndex < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_chat_sessions_one_unstarted_untitled_personal"
  DRAFT_PREDICATE = <<~SQL.squish
    started_at IS NULL AND NULLIF(BTRIM(title), '') IS NULL AND
    inbox_item_key IS NULL AND clarifying_question_issue_id IS NULL AND
    feature_intent_id IS NULL AND status <> 'archived'
  SQL

  def up
    return if index_valid?

    safety_assured do
      execute "SET LOCAL lock_timeout = '2s'"
      execute "SET LOCAL statement_timeout = '10s'"
      execute "LOCK TABLE chat_sessions IN SHARE ROW EXCLUSIVE MODE"
      execute "SET LOCAL paid.bypass_tenant_rls = 'true'"
      execute "SELECT id FROM chat_sessions WHERE #{DRAFT_PREDICATE} FOR UPDATE"
      mark_referenced_drafts_started
      archive_surplus_closed_drafts

      if index_exists?(:chat_sessions, name: INDEX_NAME)
        execute "REINDEX INDEX #{connection.quote_table_name(INDEX_NAME)}"
      else
        add_index :chat_sessions, :created_by_id, unique: true,
          where: DRAFT_PREDICATE, name: INDEX_NAME
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Archived chat sessions cannot be restored automatically"
  end

  private

  def index_valid?
    select_value(<<~SQL.squish) == true
      SELECT indisvalid AND indisready
      FROM pg_index
      WHERE indexrelid = to_regclass(#{connection.quote(INDEX_NAME)})
    SQL
  end

  def archive_surplus_closed_drafts
    duplicates = select_all(<<~SQL.squish).to_a
      WITH ranked AS (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY created_by_id ORDER BY
            CASE status WHEN 'active' THEN 0 WHEN 'idle' THEN 1 ELSE 2 END,
            created_at DESC, id DESC
        ) AS position
        FROM chat_sessions
        WHERE #{DRAFT_PREDICATE} AND created_by_id IS NOT NULL
      )
      SELECT chat_sessions.id, chat_sessions.status,
        chat_sessions.container_capability,
        chat_sessions.container_id, chat_sessions.workspace_volume,
        EXISTS (
          SELECT 1 FROM chat_messages
          WHERE chat_messages.chat_session_id = chat_sessions.id
            AND chat_messages.role <> 'system'
        ) AS has_content,
        EXISTS (
          SELECT 1 FROM chat_session_projects
          WHERE chat_session_projects.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM chat_turns
          WHERE chat_turns.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM chat_diagrams
          WHERE chat_diagrams.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM chat_investigations
          WHERE chat_investigations.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM clarifying_question_progresses
          WHERE clarifying_question_progresses.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM chat_turn_lifecycle_events
          WHERE chat_turn_lifecycle_events.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM token_usages
          WHERE token_usages.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM api_usage_attempts
          WHERE api_usage_attempts.chat_session_id = chat_sessions.id
        ) OR EXISTS (
          SELECT 1 FROM change_intents
          WHERE change_intents.chat_session_id = chat_sessions.id
        ) AS has_dependents
      FROM chat_sessions
      JOIN ranked ON ranked.id = chat_sessions.id
      WHERE ranked.position > 1
    SQL

    unsafe = duplicates.reject do |draft|
      draft.fetch("status") == "closed" && %w[none stopped].include?(draft.fetch("container_capability")) &&
        draft["container_id"].nil? &&
        draft["workspace_volume"].nil? && !draft.fetch("has_content") &&
        !draft.fetch("has_dependents")
    end
    raise "Cannot safely repair #{INDEX_NAME}; inspect chat sessions #{unsafe.map { |draft| draft.fetch('id') }.join(', ')}" if unsafe.any?

    ids = duplicates.map { |draft| Integer(draft.fetch("id")) }
    return if ids.empty?

    execute <<~SQL.squish
      UPDATE chat_sessions
      SET status = 'archived', idle_timeout_at = NULL,
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('archived_at', NOW()::text)
      WHERE id IN (#{ids.join(', ')})
    SQL
  end

  def mark_referenced_drafts_started
    execute <<~SQL.squish
      UPDATE chat_sessions
      SET started_at = COALESCE(updated_at, created_at)
      WHERE started_at IS NULL AND (
        EXISTS (SELECT 1 FROM chat_messages WHERE chat_messages.chat_session_id = chat_sessions.id AND chat_messages.role <> 'system')
        OR EXISTS (SELECT 1 FROM chat_diagrams WHERE chat_diagrams.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM chat_investigations WHERE chat_investigations.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM chat_session_projects WHERE chat_session_projects.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM chat_turn_lifecycle_events WHERE chat_turn_lifecycle_events.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM chat_turns WHERE chat_turns.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM clarifying_question_progresses WHERE clarifying_question_progresses.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM token_usages WHERE token_usages.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM api_usage_attempts WHERE api_usage_attempts.chat_session_id = chat_sessions.id)
        OR EXISTS (SELECT 1 FROM change_intents WHERE change_intents.chat_session_id = chat_sessions.id)
      )
    SQL
  end
end
