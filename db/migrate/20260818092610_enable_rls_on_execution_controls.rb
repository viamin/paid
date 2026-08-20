# frozen_string_literal: true

# Closes the cross-tenant read/write hole on execution_controls. Without a
# policy, any tenant request context can read and toggle other tenants'
# account/project/runner/backend kill switches, and can also toggle the global
# singleton. The policy treats the global row as system-only (paid_tenant_bypass
# required) and routes tenant-scoped rows through the usual
# paid_current_account_id() check, falling back to the related FK's owning
# tenant when the row's own account_id is null (project / runner / backend).
class EnableRlsOnExecutionControls < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON execution_controls"
      execute <<~SQL
        ALTER TABLE execution_controls ENABLE ROW LEVEL SECURITY;
        ALTER TABLE execution_controls FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON execution_controls
          AS PERMISSIVE
          FOR ALL
          USING (
            paid_tenant_bypass()
            OR (
              execution_controls.scope <> 'global'
              AND (
                execution_controls.account_id = paid_current_account_id()
                OR (
                  execution_controls.account_id IS NULL
                  AND execution_controls.project_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM projects
                    WHERE projects.id = execution_controls.project_id
                      AND projects.account_id = paid_current_account_id()
                  )
                )
                OR (
                  execution_controls.account_id IS NULL
                  AND execution_controls.runner_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM runners
                    JOIN users ON users.id = runners.user_id
                    WHERE runners.id = execution_controls.runner_id
                      AND users.account_id = paid_current_account_id()
                  )
                )
                OR (
                  execution_controls.account_id IS NULL
                  AND execution_controls.docker_host_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM docker_hosts
                    WHERE docker_hosts.id = execution_controls.docker_host_id
                      AND docker_hosts.account_id = paid_current_account_id()
                  )
                )
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass()
            OR (
              execution_controls.scope <> 'global'
              AND (
                execution_controls.account_id = paid_current_account_id()
                OR (
                  execution_controls.account_id IS NULL
                  AND execution_controls.project_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM projects
                    WHERE projects.id = execution_controls.project_id
                      AND projects.account_id = paid_current_account_id()
                  )
                )
                OR (
                  execution_controls.account_id IS NULL
                  AND execution_controls.runner_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM runners
                    JOIN users ON users.id = runners.user_id
                    WHERE runners.id = execution_controls.runner_id
                      AND users.account_id = paid_current_account_id()
                  )
                )
                OR (
                  execution_controls.account_id IS NULL
                  AND execution_controls.docker_host_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM docker_hosts
                    WHERE docker_hosts.id = execution_controls.docker_host_id
                      AND docker_hosts.account_id = paid_current_account_id()
                  )
                )
              )
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON execution_controls"
      execute "ALTER TABLE execution_controls NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE execution_controls DISABLE ROW LEVEL SECURITY"
    end
  end
end
