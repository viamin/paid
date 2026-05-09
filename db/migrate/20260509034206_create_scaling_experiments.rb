# frozen_string_literal: true

class CreateScalingExperiments < ActiveRecord::Migration[8.1]
  def up
    create_table :scaling_experiments,
      comment: "Controlled orchestration experiments for measuring how feature outcomes change as the agent count changes." do |t|
      t.references :project,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project for tenant isolation and experiment segmentation."
      t.string :name,
        null: false,
        limit: 255,
        comment: "Human-readable experiment name displayed in dashboards and logs."
      t.text :hypothesis,
        null: false,
        comment: "Expected scaling behavior being tested, such as diminishing returns after a certain agent count."
      t.string :dimension,
        null: false,
        limit: 50,
        default: "agent_count",
        comment: "Scaling dimension under test. Agent count is the initial supported dimension."
      t.jsonb :values_tested,
        null: false,
        default: [],
        comment: "Ordered list of experiment arms, such as [1, 2, 4], for the tested dimension."
      t.integer :control_value,
        null: false,
        comment: "Baseline arm used as the control when comparing experiment results."
      t.jsonb :context_filter,
        null: false,
        default: {},
        comment: "Eligibility filter for safely including only comparable workflows in the experiment."
      t.string :status,
        null: false,
        limit: 50,
        default: "draft",
        comment: "Lifecycle state for the experiment: draft, running, completed, or cancelled."
      t.integer :min_samples_per_value,
        null: false,
        default: 2,
        comment: "Minimum number of recorded workflows required for each tested value before the experiment can complete."
      t.integer :traffic_percentage,
        null: false,
        default: 100,
        comment: "Percent of eligible workflows allowed into the experiment."
      t.jsonb :cached_summary,
        null: false,
        default: {},
        comment: "Persisted descriptive summary for later analysis services and polling UIs."
      t.string :summary_samples_key,
        comment: "Cache key derived from per-arm sample counts so summaries can be reused until data changes."
      t.datetime :started_at,
        comment: "Timestamp when the experiment started assigning workflows."
      t.datetime :completed_at,
        comment: "Timestamp when the experiment stopped collecting data."
      t.timestamps
    end

    add_index :scaling_experiments,
      [ :project_id, :dimension, :status ],
      name: "idx_scaling_experiments_project_dimension_status"
    add_index :scaling_experiments,
      [ :project_id, :dimension ],
      unique: true,
      where: "((status)::text = 'running'::text)",
      name: "idx_scaling_experiments_one_running_dimension"

    create_table :scaling_experiment_assignments,
      comment: "Workflow-scoped assignments and result snapshots for scaling experiments." do |t|
      t.references :scaling_experiment,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Parent scaling experiment for this assignment."
      t.references :project,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project copied onto the assignment to simplify isolation and queries."
      t.references :issue,
        null: true,
        index: false,
        foreign_key: { on_delete: :nullify },
        comment: "Parent feature issue whose orchestration workflow was assigned."
      t.references :scaling_observation,
        null: true,
        index: false,
        foreign_key: { on_delete: :nullify },
        comment: "Captured observation recorded for this assigned workflow once execution completes."
      t.string :workflow_id,
        null: false,
        limit: 255,
        comment: "Temporal workflow ID used as the stable experiment sample identifier."
      t.integer :assigned_value,
        null: false,
        comment: "Experiment arm chosen for the workflow, such as the requested agent count cap."
      t.string :outcome_status,
        null: false,
        limit: 50,
        default: "assigned",
        comment: "Capture state for the assignment: assigned, recorded, or skipped."
      t.jsonb :execution_plan,
        null: false,
        default: {},
        comment: "Structured execution plan describing how the assigned arm should be applied safely."
      t.jsonb :outcome_summary,
        null: false,
        default: {},
        comment: "Normalized snapshot of the resulting observation for downstream analysis services."
      t.timestamps
    end

    add_index :scaling_experiment_assignments,
      [ :scaling_experiment_id, :workflow_id ],
      unique: true,
      name: "idx_scaling_experiment_assignments_unique"
    add_index :scaling_experiment_assignments,
      :scaling_observation_id,
      unique: true,
      where: "(scaling_observation_id IS NOT NULL)",
      name: "idx_scaling_experiment_assignments_observation_unique"
    add_index :scaling_experiment_assignments,
      [ :project_id, :outcome_status, :created_at ],
      name: "idx_scaling_experiment_assignments_project_status"
    add_index :scaling_experiment_assignments,
      [ :project_id, :created_at ],
      name: "idx_scaling_experiment_assignments_project_recent"

    execute <<~SQL
      ALTER TABLE scaling_experiments ENABLE ROW LEVEL SECURITY;
      ALTER TABLE scaling_experiments FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON scaling_experiments
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = scaling_experiments.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = scaling_experiments.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
    SQL

    execute <<~SQL
      ALTER TABLE scaling_experiment_assignments ENABLE ROW LEVEL SECURITY;
      ALTER TABLE scaling_experiment_assignments FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON scaling_experiment_assignments
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = scaling_experiment_assignments.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = scaling_experiment_assignments.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON scaling_experiment_assignments"
    execute "ALTER TABLE scaling_experiment_assignments NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE scaling_experiment_assignments DISABLE ROW LEVEL SECURITY"

    execute "DROP POLICY IF EXISTS tenant_isolation ON scaling_experiments"
    execute "ALTER TABLE scaling_experiments NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE scaling_experiments DISABLE ROW LEVEL SECURITY"

    drop_table :scaling_experiment_assignments
    drop_table :scaling_experiments
  end
end
