# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
class CreateProjectDelegationCheckpoints < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_checkpoints do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, foreign_key: true
      t.string :design_revision, null: false
      t.string :acceptance_revision, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :groups, null: false, default: []
      t.timestamps
    end

    add_index :project_delegation_checkpoints, %i[project_id issue_id status],
      name: "index_delegation_checkpoints_on_project_issue_status"
    add_index :project_delegation_checkpoints,
      %i[project_id design_revision acceptance_revision],
      name: "index_delegation_checkpoints_on_project_revisions"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_checkpoints
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_checkpoints ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_checkpoints FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_checkpoints"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_checkpoints
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_checkpoints"
      execute "ALTER TABLE project_delegation_checkpoints NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_checkpoints DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_checkpoints.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_checkpoints.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        project_delegation_checkpoints.issue_id IS NULL
        OR EXISTS (
          SELECT 1 FROM issues
          INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
          WHERE issues.id = project_delegation_checkpoints.issue_id
            AND issues.project_id = project_delegation_checkpoints.project_id
            AND issue_projects.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
