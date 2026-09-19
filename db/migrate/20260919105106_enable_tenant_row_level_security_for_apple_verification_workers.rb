# frozen_string_literal: true

class EnableTenantRowLevelSecurityForAppleVerificationWorkers < ActiveRecord::Migration[8.1]
  TABLES = %w[
    apple_worker_profiles
    apple_verification_workflow_revisions
    apple_verification_attempts
    apple_verification_waivers
  ].freeze

  def up
    safety_assured do
      enable_tenant_policy("apple_worker_profiles", profile_condition)
      enable_tenant_policy("apple_verification_workflow_revisions", workflow_condition)
      enable_tenant_policy("apple_verification_attempts", attempt_condition)
      enable_tenant_policy("apple_verification_waivers", waiver_condition)
    end
  end

  def down
    safety_assured do
      TABLES.each do |table|
        next unless table_exists?(table)

        qualified_table = quote_table_name(table)
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{qualified_table}"
        execute "ALTER TABLE #{qualified_table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{qualified_table} DISABLE ROW LEVEL SECURITY"
      end
    end
  end

  private

  def enable_tenant_policy(table, condition)
    return unless table_exists?(table)

    qualified_table = quote_table_name(table)

    execute "ALTER TABLE #{qualified_table} ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE #{qualified_table} FORCE ROW LEVEL SECURITY"
    execute "DROP POLICY IF EXISTS tenant_isolation ON #{qualified_table}"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON #{qualified_table}
      AS PERMISSIVE
      FOR ALL
      USING (paid_tenant_bypass() OR (#{condition}))
      WITH CHECK (paid_tenant_bypass() OR (#{condition}))
    SQL
  end

  def account_condition(table)
    "#{table}.account_id = paid_current_account_id()"
  end

  def project_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = #{table}.project_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def optional_user_condition(table, column)
    <<~SQL.squish
      (
        #{table}.#{column} IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = #{table}.#{column}
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end

  def profile_condition
    <<~SQL.squish
      #{account_condition("apple_worker_profiles")}
      AND #{optional_user_condition("apple_worker_profiles", "created_by_id")}
    SQL
  end

  def workflow_condition
    <<~SQL.squish
      #{account_condition("apple_verification_workflow_revisions")}
      AND #{project_condition("apple_verification_workflow_revisions")}
      AND EXISTS (
        SELECT 1 FROM apple_worker_profiles
        WHERE apple_worker_profiles.id = apple_verification_workflow_revisions.apple_worker_profile_id
          AND apple_worker_profiles.account_id = paid_current_account_id()
      )
      AND #{optional_user_condition("apple_verification_workflow_revisions", "approved_by_id")}
    SQL
  end

  def attempt_condition
    <<~SQL.squish
      #{account_condition("apple_verification_attempts")}
      AND #{project_condition("apple_verification_attempts")}
      AND EXISTS (
        SELECT 1 FROM apple_verification_workflow_revisions
        WHERE apple_verification_workflow_revisions.id = apple_verification_attempts.apple_verification_workflow_revision_id
          AND apple_verification_workflow_revisions.account_id = paid_current_account_id()
          AND apple_verification_workflow_revisions.project_id = apple_verification_attempts.project_id
          AND apple_verification_workflow_revisions.apple_worker_profile_id = apple_verification_attempts.apple_worker_profile_id
      )
      AND (
        apple_verification_attempts.agent_run_id IS NULL
        OR EXISTS (
          SELECT 1 FROM agent_runs
          WHERE agent_runs.id = apple_verification_attempts.agent_run_id
            AND agent_runs.project_id = apple_verification_attempts.project_id
        )
      )
    SQL
  end

  def waiver_condition
    <<~SQL.squish
      #{account_condition("apple_verification_waivers")}
      AND #{project_condition("apple_verification_waivers")}
      AND EXISTS (
        SELECT 1 FROM apple_verification_attempts
        WHERE apple_verification_attempts.id = apple_verification_waivers.apple_verification_attempt_id
          AND apple_verification_attempts.account_id = paid_current_account_id()
          AND apple_verification_attempts.project_id = apple_verification_waivers.project_id
          AND apple_verification_attempts.apple_verification_workflow_revision_id = apple_verification_waivers.apple_verification_workflow_revision_id
      )
      AND EXISTS (
        SELECT 1 FROM users
        WHERE users.id = apple_verification_waivers.created_by_id
          AND users.account_id = paid_current_account_id()
      )
    SQL
  end
end
