# frozen_string_literal: true

# @spec POST-DEPLOY-CHECK-001
class CreatePostDeployCheckRuns < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending running succeeded failed unknown].freeze

  def up
    create_table :post_deploy_check_runs,
      comment: "Idempotent attempts and evidence for trusted, read-only, allowlisted post-deploy " \
        "measurements against live tenant data (see docs/intent/post-deploy-measurement)." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_issue, foreign_key: { to_table: :issues, on_delete: :nullify }
      t.references :superseded_by, foreign_key: { to_table: :post_deploy_check_runs, on_delete: :nullify }
      t.string :check_key, null: false
      t.integer :check_version, null: false
      t.string :deployed_revision
      t.string :idempotency_key, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :result, null: false, default: {}
      t.text :failure_reason
      t.datetime :executed_at
      t.timestamps
    end

    add_index :post_deploy_check_runs, %i[account_id idempotency_key], unique: true,
      name: "index_post_deploy_check_runs_idempotency"
    add_index :post_deploy_check_runs, %i[project_id check_key], name: "index_post_deploy_check_runs_project_check"
    add_check_constraint :post_deploy_check_runs, "status IN ('#{STATUSES.join("', '")}')",
      name: "post_deploy_check_runs_status"

    apply_rls
  end

  def down
    remove_rls
    drop_table :post_deploy_check_runs
  end

  private

  def apply_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE post_deploy_check_runs ENABLE ROW LEVEL SECURITY;
        ALTER TABLE post_deploy_check_runs FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON post_deploy_check_runs AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (post_deploy_check_runs.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (post_deploy_check_runs.account_id = paid_current_account_id()));
      SQL
    end
  end

  def remove_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON post_deploy_check_runs"
      execute "ALTER TABLE post_deploy_check_runs NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE post_deploy_check_runs DISABLE ROW LEVEL SECURITY"
    end
  end
end
