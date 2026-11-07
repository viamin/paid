# frozen_string_literal: true

class CreatePostDeployMeasurements < ActiveRecord::Migration[8.1]
  def up
    create_table :post_deploy_measurements, comment: "Trusted, allowlisted, read-only post-deploy checks recorded as closeout evidence (#4907)." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :check_key, null: false, comment: "Registry key of the allowlisted check."
      t.integer :check_version, null: false, default: 1, comment: "Check semantics revision; evidence is only current for the registry's version."
      t.text :criterion, null: false, comment: "Exact acceptance criterion the measurement evidences."
      t.string :prerequisite_identity, comment: "Prerequisite occurrence identity this measurement may release."
      t.string :status, null: false, default: "pending", comment: "pending, running, awaiting_deployment, passed, failed, or unknown."
      t.string :deployed_revision, null: false, default: "", comment: "Deployment generation measured; empty until the target revision is deployed."
      t.integer :deployed_pr_number
      t.datetime :deployed_at
      t.integer :attempts, null: false, default: 0
      t.datetime :executed_at
      t.integer :duration_ms
      t.jsonb :counts, null: false, default: {}, comment: "Measured counts, including the totals that make a zero interpretable."
      t.jsonb :details, null: false, default: {}, comment: "Scope, baseline, target, deployment provenance, and next action."
      t.text :failure_reason
      t.datetime :released_at, comment: "When the bound prerequisite was released from this evidence."
      t.timestamps
    end

    add_index :post_deploy_measurements, [ :issue_id, :check_key, :check_version, :deployed_revision ],
      unique: true, name: "index_post_deploy_measurements_on_idempotency_key"
    add_index :post_deploy_measurements, [ :status, :attempts ],
      name: "index_post_deploy_measurements_on_status_and_attempts"
    add_check_constraint :post_deploy_measurements, "check_version > 0", name: "chk_post_deploy_measurements_version"
    add_check_constraint :post_deploy_measurements,
      "status IN ('pending', 'running', 'awaiting_deployment', 'passed', 'failed', 'unknown')",
      name: "chk_post_deploy_measurements_status"
    add_check_constraint :post_deploy_measurements, "attempts >= 0", name: "chk_post_deploy_measurements_attempts"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :post_deploy_measurements
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE post_deploy_measurements ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE post_deploy_measurements FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON post_deploy_measurements"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON post_deploy_measurements
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON post_deploy_measurements"
      execute "ALTER TABLE post_deploy_measurements NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE post_deploy_measurements DISABLE ROW LEVEL SECURITY"
    end
  end

  def tenant_condition
    <<~SQL.squish
      post_deploy_measurements.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = post_deploy_measurements.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
        WHERE issues.id = post_deploy_measurements.issue_id
          AND issues.project_id = post_deploy_measurements.project_id
          AND issue_projects.account_id = paid_current_account_id()
      )
      AND (
        post_deploy_measurements.requested_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = post_deploy_measurements.requested_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
