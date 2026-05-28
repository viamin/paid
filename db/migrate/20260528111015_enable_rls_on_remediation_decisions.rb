# frozen_string_literal: true

class EnableRlsOnRemediationDecisions < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        ALTER TABLE remediation_decisions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE remediation_decisions FORCE ROW LEVEL SECURITY;

        CREATE POLICY tenant_isolation ON remediation_decisions
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass()
          OR remediation_decisions.account_id = paid_current_account_id()
        )
        WITH CHECK (
          paid_tenant_bypass()
          OR remediation_decisions.account_id = paid_current_account_id()
        );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON remediation_decisions"
      execute "ALTER TABLE remediation_decisions NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE remediation_decisions DISABLE ROW LEVEL SECURITY"
    end
  end
end
