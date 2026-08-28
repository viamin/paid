# frozen_string_literal: true

# @spec EXEC-USAGE-001
class EnableRlsOnExecutionUsages < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:execution_usages)

    safety_assured do
      execute "ALTER TABLE execution_usages ENABLE ROW LEVEL SECURITY" unless row_level_security_enabled?
      execute "ALTER TABLE execution_usages FORCE ROW LEVEL SECURITY" unless row_level_security_forced?
      execute(tenant_isolation_policy_sql) unless tenant_policy_present?
    end
  end

  def down
    return unless table_exists?(:execution_usages)

    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON execution_usages" if tenant_policy_present? }
    safety_assured { execute "ALTER TABLE execution_usages NO FORCE ROW LEVEL SECURITY" if row_level_security_forced? }
    safety_assured { execute "ALTER TABLE execution_usages DISABLE ROW LEVEL SECURITY" if row_level_security_enabled? }
  end

  private

  def tenant_isolation_policy_sql
    <<~SQL
      CREATE POLICY tenant_isolation ON execution_usages
        AS PERMISSIVE FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM agent_runs
              JOIN projects ON projects.id = agent_runs.project_id
              WHERE agent_runs.id = execution_usages.agent_run_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM agent_runs
              JOIN projects ON projects.id = agent_runs.project_id
              WHERE agent_runs.id = execution_usages.agent_run_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        );
    SQL
  end

  def tenant_policy_present?
    select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'execution_usages'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?
    truthy?(select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.execution_usages'::regclass"))
  end

  def row_level_security_forced?
    truthy?(select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.execution_usages'::regclass"))
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
