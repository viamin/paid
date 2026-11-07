# frozen_string_literal: true

class CreateAdmissionSnapshots < ActiveRecord::Migration[8.1]
  def up
    create_table :admission_snapshots do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :bounded_delegated_action, null: false, foreign_key: true
      t.string :boundary, null: false
      t.string :action, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.string :status, null: false, default: "active"
      t.datetime :expires_at
      t.text :rollback_reason
      t.timestamps
    end

    add_index :admission_snapshots, [:project_id, :issue_id, :action],
      name: "index_admission_snapshots_on_project_issue_action"
    add_index :admission_snapshots, [:bounded_delegated_action_id, :boundary],
      name: "index_admission_snapshots_on_action_and_boundary", unique: true
    add_index :admission_snapshots, [:status, :expires_at],
      name: "index_admission_snapshots_on_status_and_expiry"
    add_index :admission_snapshots, [:account_id, :created_at],
      name: "index_admission_snapshots_on_account_and_created_at"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :admission_snapshots
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE admission_snapshots ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE admission_snapshots FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON admission_snapshots"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON admission_snapshots
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON admission_snapshots"
      execute "ALTER TABLE admission_snapshots NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE admission_snapshots DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      admission_snapshots.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = admission_snapshots.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
        WHERE issues.id = admission_snapshots.issue_id
          AND issues.project_id = admission_snapshots.project_id
          AND issue_projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM bounded_delegated_actions
        WHERE bounded_delegated_actions.id = admission_snapshots.bounded_delegated_action_id
          AND bounded_delegated_actions.account_id = paid_current_account_id()
      )
    SQL
  end
end
