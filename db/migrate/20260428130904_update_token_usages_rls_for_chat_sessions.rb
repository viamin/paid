# frozen_string_literal: true

class UpdateTokenUsagesRlsForChatSessions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DROP POLICY IF EXISTS tenant_isolation ON token_usages;

      CREATE POLICY tenant_isolation ON token_usages
        USING (
          paid_tenant_bypass()
          OR (
            (agent_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM agent_runs
              INNER JOIN projects ON projects.id = agent_runs.project_id
              WHERE agent_runs.id = token_usages.agent_run_id
                AND projects.account_id = paid_current_account_id()
            ))
            OR (knowledge_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM knowledge_runs
              INNER JOIN projects ON projects.id = knowledge_runs.project_id
              WHERE knowledge_runs.id = token_usages.knowledge_run_id
                AND projects.account_id = paid_current_account_id()
            ))
            OR (chat_session_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = token_usages.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            ))
          )
        )
        WITH CHECK (
          paid_tenant_bypass()
          OR (
            (agent_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM agent_runs
              INNER JOIN projects ON projects.id = agent_runs.project_id
              WHERE agent_runs.id = token_usages.agent_run_id
                AND projects.account_id = paid_current_account_id()
            ))
            OR (knowledge_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM knowledge_runs
              INNER JOIN projects ON projects.id = knowledge_runs.project_id
              WHERE knowledge_runs.id = token_usages.knowledge_run_id
                AND projects.account_id = paid_current_account_id()
            ))
            OR (chat_session_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = token_usages.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            ))
          )
        );
    SQL
  end

  def down
    execute <<~SQL
      DROP POLICY IF EXISTS tenant_isolation ON token_usages;

      CREATE POLICY tenant_isolation ON token_usages
        USING (
          paid_tenant_bypass()
          OR (
            (agent_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM agent_runs
              INNER JOIN projects ON projects.id = agent_runs.project_id
              WHERE agent_runs.id = token_usages.agent_run_id
                AND projects.account_id = paid_current_account_id()
            ))
            OR (knowledge_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM knowledge_runs
              INNER JOIN projects ON projects.id = knowledge_runs.project_id
              WHERE knowledge_runs.id = token_usages.knowledge_run_id
                AND projects.account_id = paid_current_account_id()
            ))
          )
        )
        WITH CHECK (
          paid_tenant_bypass()
          OR (
            (agent_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM agent_runs
              INNER JOIN projects ON projects.id = agent_runs.project_id
              WHERE agent_runs.id = token_usages.agent_run_id
                AND projects.account_id = paid_current_account_id()
            ))
            OR (knowledge_run_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM knowledge_runs
              INNER JOIN projects ON projects.id = knowledge_runs.project_id
              WHERE knowledge_runs.id = token_usages.knowledge_run_id
                AND projects.account_id = paid_current_account_id()
            ))
          )
        );
    SQL
  end
end
