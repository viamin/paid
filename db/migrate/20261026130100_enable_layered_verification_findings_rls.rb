# frozen_string_literal: true

class EnableLayeredVerificationFindingsRls < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute "ALTER TABLE layered_verification_findings ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE layered_verification_findings FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = layered_verification_findings.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = layered_verification_findings.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY tenant_isolation ON layered_verification_findings"
      execute "ALTER TABLE layered_verification_findings DISABLE ROW LEVEL SECURITY"
    end
  end
end
