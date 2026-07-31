# frozen_string_literal: true

# A project may use a GitHub App installation instead of a PAT, leaving
# github_token_id NULL (the chk_projects_exactly_one_github_credential check
# enforces exactly one credential). The original tenant policy required every
# visible project to reference a github_token owned by the current account, which
# hid installation-backed projects from their own account. Treat github_token_id
# as optional, mirroring how created_by_id already works; ownership is still
# gated by the account_id check.
class MakeProjectsGithubTokenOptionalInRls < ActiveRecord::Migration[8.1]
  # Ownership is still gated by the account_id check. The only change is that a
  # missing github_token no longer hides a project from its own account.
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

  # Restores the original behaviour: a github_token owned by the current account
  # is required for a project to be visible.
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
