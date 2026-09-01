# frozen_string_literal: true

class EnableRlsOnAgentRunSessionSummaries < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute "ALTER TABLE agent_run_session_summaries ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE agent_run_session_summaries FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON agent_run_session_summaries
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = agent_run_session_summaries.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = agent_run_session_summaries.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON agent_run_session_summaries"
      execute "ALTER TABLE agent_run_session_summaries NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE agent_run_session_summaries DISABLE ROW LEVEL SECURITY"
    end
  end
end
