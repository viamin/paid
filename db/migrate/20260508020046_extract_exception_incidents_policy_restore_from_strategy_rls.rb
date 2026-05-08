# frozen_string_literal: true

class ExtractExceptionIncidentsPolicyRestoreFromStrategyRls < ActiveRecord::Migration[8.1]
  def up
    execute "DROP POLICY IF EXISTS tenant_isolation ON exception_incidents"
    execute "ALTER TABLE exception_incidents ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE exception_incidents FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON exception_incidents
      AS PERMISSIVE
      FOR ALL
      USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
      WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON exception_incidents"
    execute "ALTER TABLE exception_incidents ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE exception_incidents FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON exception_incidents
        USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
        WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
    SQL
  end
end
