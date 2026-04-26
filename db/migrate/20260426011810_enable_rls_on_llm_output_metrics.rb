# frozen_string_literal: true

class EnableRlsOnLlmOutputMetrics < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE llm_output_metrics ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE llm_output_metrics FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON llm_output_metrics
      AS PERMISSIVE
      FOR ALL
      USING (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = llm_output_metrics.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      )
      WITH CHECK (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = llm_output_metrics.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      )
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON llm_output_metrics"
    execute "ALTER TABLE llm_output_metrics NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE llm_output_metrics DISABLE ROW LEVEL SECURITY"
  end
end
