# frozen_string_literal: true

class CreateBoundedDelegatedActions < ActiveRecord::Migration[8.1]
  def up
    create_table :bounded_delegated_actions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :evidence, null: false, default: {}
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :bounded_delegated_actions, [ :project_id, :issue_id, :action ],
      name: "index_bounded_actions_on_project_issue_action"
    add_index :bounded_delegated_actions, [ :status, :expires_at ],
      name: "index_bounded_actions_on_status_and_expiry"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :bounded_delegated_actions
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE bounded_delegated_actions ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE bounded_delegated_actions FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON bounded_delegated_actions"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON bounded_delegated_actions
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON bounded_delegated_actions"
      execute "ALTER TABLE bounded_delegated_actions NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE bounded_delegated_actions DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      bounded_delegated_actions.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = bounded_delegated_actions.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
        WHERE issues.id = bounded_delegated_actions.issue_id
          AND issues.project_id = bounded_delegated_actions.project_id
          AND issue_projects.account_id = paid_current_account_id()
      )
      AND (
        bounded_delegated_actions.created_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = bounded_delegated_actions.created_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
      AND (
        bounded_delegated_actions.revoked_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = bounded_delegated_actions.revoked_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
