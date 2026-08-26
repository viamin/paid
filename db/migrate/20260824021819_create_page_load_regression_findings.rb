# frozen_string_literal: true

class CreatePageLoadRegressionFindings < ActiveRecord::Migration[8.1]
  def up
    create_table :page_load_regression_findings, comment: "Confirmed page load regressions on a pull request. At most one open finding per pull request and route; actionable findings drive the performance_regression follow-up run." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify }, comment: "The capture run that raised the finding."
      t.integer :pull_request_number, null: false
      t.string :route_name, limit: 255, null: false
      t.string :comparison_metric, limit: 20, null: false, comment: "Metric the comparison used: lcp_ms or the load_ms fallback."
      t.integer :baseline_ms, null: false
      t.integer :current_ms, null: false
      t.integer :delta_ms, null: false
      t.decimal :delta_ratio, precision: 8, scale: 4, null: false
      t.string :baseline_commit_sha, limit: 64, null: false
      t.string :commit_sha, limit: 64, null: false
      t.jsonb :sample_spread, null: false, default: {}, comment: "Min/max of the samples behind each side of the comparison."
      t.jsonb :changed_files, null: false, default: [], comment: "The pull request's changed files at the time of the finding, carried into the follow-up run's prompt."
      t.boolean :actionable, null: false, default: false, comment: "True when the route was in the capture's screenshot hints — a page this pull request actually touched."
      t.string :status, limit: 20, null: false, default: "open", comment: "open, resolved (back within threshold), or superseded (route no longer measured)."
      t.datetime :resolved_at

      t.timestamps null: false
    end

    add_index :page_load_regression_findings,
      [ :project_id, :pull_request_number, :route_name ],
      unique: true, where: "status = 'open'", name: "idx_page_load_findings_one_open_per_route"
    add_index :page_load_regression_findings,
      [ :project_id, :pull_request_number, :status ], name: "idx_page_load_findings_pr_status"

    add_check_constraint :page_load_regression_findings,
      "status IN ('open', 'resolved', 'superseded')", name: "chk_page_load_findings_status_valid"

    safety_assured do
      execute <<~SQL
        ALTER TABLE page_load_regression_findings ENABLE ROW LEVEL SECURITY;
        ALTER TABLE page_load_regression_findings FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON page_load_regression_findings
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (page_load_regression_findings.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (page_load_regression_findings.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON page_load_regression_findings" }
    safety_assured { execute "ALTER TABLE page_load_regression_findings NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE page_load_regression_findings DISABLE ROW LEVEL SECURITY" }

    drop_table :page_load_regression_findings
  end
end
