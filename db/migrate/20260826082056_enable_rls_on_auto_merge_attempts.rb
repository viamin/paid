# frozen_string_literal: true

# @spec AUTO-MERGE-004
class EnableRlsOnAutoMergeAttempts < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:auto_merge_attempts)

    safety_assured do
      execute "ALTER TABLE auto_merge_attempts ENABLE ROW LEVEL SECURITY" unless row_level_security_enabled?
      execute "ALTER TABLE auto_merge_attempts FORCE ROW LEVEL SECURITY" unless row_level_security_forced?
      execute(tenant_isolation_policy_sql) unless tenant_policy_present?
    end
  end

  def down
    return unless table_exists?(:auto_merge_attempts)

    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON auto_merge_attempts" if tenant_policy_present? }
    safety_assured { execute "ALTER TABLE auto_merge_attempts NO FORCE ROW LEVEL SECURITY" if row_level_security_forced? }
    safety_assured { execute "ALTER TABLE auto_merge_attempts DISABLE ROW LEVEL SECURITY" if row_level_security_enabled? }
  end

  private

  def tenant_isolation_policy_sql
    <<~SQL
      CREATE POLICY tenant_isolation ON auto_merge_attempts
        AS PERMISSIVE FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = auto_merge_attempts.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = auto_merge_attempts.project_id
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
        AND tablename = 'auto_merge_attempts'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?
    truthy?(select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.auto_merge_attempts'::regclass"))
  end

  def row_level_security_forced?
    truthy?(select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.auto_merge_attempts'::regclass"))
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
