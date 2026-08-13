# frozen_string_literal: true

class EnableRlsOnLlmOutputMetrics < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute "ALTER TABLE llm_output_metrics ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE llm_output_metrics FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON llm_output_metrics
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            llm_output_metrics.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            llm_output_metrics.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON llm_output_metrics"
      execute "ALTER TABLE llm_output_metrics NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE llm_output_metrics DISABLE ROW LEVEL SECURITY"
    end
  end
end
