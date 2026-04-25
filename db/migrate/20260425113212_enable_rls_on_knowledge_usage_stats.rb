# frozen_string_literal: true

class EnableRlsOnKnowledgeUsageStats < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE knowledge_usage_stats ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE knowledge_usage_stats FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON knowledge_usage_stats
      AS PERMISSIVE
      FOR ALL
      USING (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = knowledge_usage_stats.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      )
      WITH CHECK (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = knowledge_usage_stats.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      )
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON knowledge_usage_stats"
    execute "ALTER TABLE knowledge_usage_stats NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE knowledge_usage_stats DISABLE ROW LEVEL SECURITY"
  end
end
