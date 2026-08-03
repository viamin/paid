# frozen_string_literal: true

# db/schema.rb does not preserve row-level security policies, so a schema load
# followed by db:prepare can resurrect the older strict projects policy that
# requires a github_token-owned row. Reapply the intended relaxed condition so
# GitHub App-backed projects stay visible to their own account on fresh DBs.
class AllowAppBackedProjectsInTenantRls < ActiveRecord::Migration[8.1]
  RELAXED_CONDITION = <<~SQL.squish
    projects.account_id = paid_current_account_id()
    AND (
      projects.github_token_id IS NULL
      OR EXISTS (
        SELECT 1 FROM github_tokens
        WHERE github_tokens.id = projects.github_token_id
          AND github_tokens.account_id = paid_current_account_id()
      )
    )
    AND (
      projects.created_by_id IS NULL
      OR EXISTS (
        SELECT 1 FROM users
        WHERE users.id = projects.created_by_id
          AND users.account_id = paid_current_account_id()
      )
    )
  SQL

  STRICT_CONDITION = <<~SQL.squish
    projects.account_id = paid_current_account_id()
    AND EXISTS (
      SELECT 1 FROM github_tokens
      WHERE github_tokens.id = projects.github_token_id
        AND github_tokens.account_id = paid_current_account_id()
    )
    AND (
      projects.created_by_id IS NULL
      OR EXISTS (
        SELECT 1 FROM users
        WHERE users.id = projects.created_by_id
          AND users.account_id = paid_current_account_id()
      )
    )
  SQL

  def up
    safety_assured { recreate_projects_policy(RELAXED_CONDITION) }
  end

  def down
    safety_assured { recreate_projects_policy(STRICT_CONDITION) }
  end

  private

  def recreate_projects_policy(condition)
    execute "DROP POLICY IF EXISTS tenant_isolation ON projects"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON projects
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{condition}))
    SQL
  end
end
