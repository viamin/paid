# frozen_string_literal: true

# Tenant RLS for the delegation-pilot tables, matching the policy shape the
# bounded-authorization and trusted-measurement tables already carry
# (POSTGRESQL-PERSISTENCE-001): every pilot row is readable and writable only
# inside its owning tenant.
class EnableTenantRlsOnDelegationPilotTables < ActiveRecord::Migration[8.1]
  def up
    enable_tenant_rls(:delegation_pilot_enrollments)
    enable_tenant_rls(:delegation_pilot_metric_snapshots)
  end

  def down
    disable_tenant_rls(:delegation_pilot_metric_snapshots)
    disable_tenant_rls(:delegation_pilot_enrollments)
  end

  private

  def enable_tenant_rls(table)
    safety_assured do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON #{table}
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition(table)}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition(table)}))
      SQL
    end
  end

  def disable_tenant_rls(table)
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end

  def tenant_condition(table)
    project_check = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = #{table}.project_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL

    return "#{table}.account_id = paid_current_account_id() AND #{project_check}" if table == :delegation_pilot_enrollments

    <<~SQL.squish
      #{table}.account_id = paid_current_account_id()
      AND #{project_check}
      AND EXISTS (
        SELECT 1 FROM delegation_pilot_enrollments
        WHERE delegation_pilot_enrollments.id = #{table}.enrollment_id
          AND delegation_pilot_enrollments.account_id = paid_current_account_id()
      )
    SQL
  end
end
