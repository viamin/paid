class UpdateProjectsTenantRlsCredentialReferences < ActiveRecord::Migration[8.1]
  def up
    replace_projects_policy(credential_condition)
  end

  def down
    replace_projects_policy(token_condition)
  end

  private

  def replace_projects_policy(condition)
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON projects"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON projects
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR (#{condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{condition}))
      SQL
    end
  end

  def credential_condition
    <<~SQL.squish
      projects.account_id = paid_current_account_id()
      AND (
        EXISTS (
          SELECT 1 FROM github_tokens
          WHERE github_tokens.id = projects.github_token_id
            AND github_tokens.account_id = paid_current_account_id()
        )
        OR EXISTS (
          SELECT 1 FROM github_installations
          WHERE github_installations.id = projects.github_installation_id
            AND github_installations.account_id = paid_current_account_id()
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
  end

  def token_condition
    <<~SQL.squish
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
  end
end
