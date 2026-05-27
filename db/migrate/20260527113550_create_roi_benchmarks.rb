# frozen_string_literal: true

class CreateRoiBenchmarks < ActiveRecord::Migration[8.1]
  def up
    create_table :roi_benchmarks,
      comment: "Customer-specific comparison baselines used in ROI dashboards and pilot reports." do |t|
      t.references :project,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project for tenant isolation and benchmark segmentation."
      t.string :name,
        null: false,
        limit: 255,
        comment: "Human-readable benchmark label such as Human-only Baseline or Cursor Pilot."
      t.string :benchmark_type,
        null: false,
        limit: 50,
        comment: "Supported comparison class: human_only or commercial_agent."
      t.string :tool_name,
        limit: 100,
        comment: "Specific vendor or tool name when benchmark_type is commercial_agent."
      t.datetime :starts_at,
        comment: "Inclusive start of the benchmark measurement window."
      t.datetime :ends_at,
        comment: "Inclusive end of the benchmark measurement window."
      t.decimal :merge_rate,
        precision: 5,
        scale: 2,
        comment: "Accepted pull requests divided by created pull requests, stored as a percentage."
      t.decimal :average_cycle_time_hours,
        precision: 10,
        scale: 2,
        comment: "Average elapsed hours from issue intake to accepted pull request."
      t.decimal :rework_rate,
        precision: 5,
        scale: 2,
        comment: "Share of accepted pull requests requiring follow-up work, stored as a percentage."
      t.decimal :defect_escape_rate,
        precision: 5,
        scale: 2,
        comment: "Share of accepted pull requests followed by post-acceptance fix work, stored as a percentage."
      t.integer :cost_per_accepted_pr_cents,
        comment: "Blended cost for each accepted pull request in cents."
      t.integer :accepted_pr_count,
        null: false,
        default: 0,
        comment: "Accepted pull requests included in this benchmark window."
      t.text :notes,
        comment: "Free-form implementation notes captured for stakeholder review."

      t.timestamps
    end

    add_index :roi_benchmarks,
      [ :project_id, :benchmark_type, :ends_at ],
      name: "idx_roi_benchmarks_project_type_ends_at"
    add_index :roi_benchmarks,
      [ :project_id, :name ],
      name: "idx_roi_benchmarks_project_name"

    safety_assured do
      execute <<~SQL
        ALTER TABLE roi_benchmarks ENABLE ROW LEVEL SECURITY;
        ALTER TABLE roi_benchmarks FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON roi_benchmarks
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = roi_benchmarks.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = roi_benchmarks.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON roi_benchmarks"
      execute "ALTER TABLE roi_benchmarks NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE roi_benchmarks DISABLE ROW LEVEL SECURITY"
    end

    drop_table :roi_benchmarks
  end
end
