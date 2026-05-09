# frozen_string_literal: true

class CreateScalingObservations < ActiveRecord::Migration[8.1]
  def up
    create_table :scaling_observations,
      comment: "Run-level observations for studying orchestration scaling behavior across agent count, iterations, and parallelism." do |t|
      t.references :project,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project for tenant isolation and experiment segmentation."
      t.references :issue,
        null: true,
        index: false,
        foreign_key: { on_delete: :nullify },
        comment: "Parent feature issue whose orchestration emitted the observation."
      t.string :workflow_id,
        null: false,
        limit: 255,
        comment: "Temporal workflow ID for the orchestration run."
      t.string :workflow_name,
        null: false,
        limit: 255,
        comment: "Workflow class that emitted the observation."
      t.string :observation_type,
        null: false,
        limit: 100,
        default: "feature_orchestration",
        comment: "Observation category used to group comparable orchestration runs."
      t.string :status,
        null: false,
        limit: 100,
        default: "completed",
        comment: "Terminal orchestration outcome such as completed, skipped, no_capacity, partial_failure, or failed."
      t.boolean :success,
        null: false,
        default: false,
        comment: "Whether the orchestration run achieved its intended terminal outcome."
      t.boolean :parallel_execution,
        null: false,
        default: false,
        comment: "Whether the workflow attempted parallel child execution."
      t.integer :task_count,
        null: false,
        default: 0,
        comment: "Number of planned sub-tasks in the decomposition."
      t.integer :dependency_edge_count,
        null: false,
        default: 0,
        comment: "Total dependency edges across planned sub-tasks."
      t.integer :parallelizable_group_count,
        null: false,
        default: 0,
        comment: "Count of planned parallel groups containing more than one task."
      t.integer :agent_count_planned,
        null: false,
        default: 0,
        comment: "Number of agents the orchestration planned to use."
      t.integer :agent_count_launched,
        null: false,
        default: 0,
        comment: "Number of child agent runs actually launched."
      t.integer :agent_count_succeeded,
        null: false,
        default: 0,
        comment: "Number of launched child agent runs that completed successfully."
      t.integer :agent_count_failed,
        null: false,
        default: 0,
        comment: "Number of launched child agent runs that completed unsuccessfully."
      t.integer :agent_count_blocked,
        null: false,
        default: 0,
        comment: "Number of planned tasks that never launched because of dependencies, deadlines, or capacity."
      t.integer :total_iterations,
        null: false,
        default: 0,
        comment: "Sum of iterations across launched child agent runs."
      t.integer :max_iterations,
        null: false,
        default: 0,
        comment: "Maximum iterations observed on any launched child agent run."
      t.integer :parallelism_planned,
        null: false,
        default: 0,
        comment: "Maximum planned same-wave task count from decomposition parallel groups."
      t.integer :parallelism_observed,
        null: false,
        default: 0,
        comment: "Maximum child workflow batch size actually launched concurrently."
      t.integer :batch_count,
        null: false,
        default: 0,
        comment: "Number of execution batches used by the parallel workflow."
      t.integer :duration_seconds,
        comment: "Elapsed wall-clock seconds for the orchestration workflow."
      t.integer :total_cost_cents,
        null: false,
        default: 0,
        comment: "Sum of cost_cents across launched child agent runs."
      t.integer :total_input_tokens,
        null: false,
        default: 0,
        comment: "Sum of input tokens across launched child agent runs."
      t.integer :total_output_tokens,
        null: false,
        default: 0,
        comment: "Sum of output tokens across launched child agent runs."
      t.jsonb :metadata,
        null: false,
        default: {},
        comment: "Structured detail for experiments, including batch sizes, errors, and linked child runs."
      t.timestamps
    end

    add_index :scaling_observations,
      [ :project_id, :workflow_id ],
      unique: true,
      name: "idx_scaling_observations_project_workflow"
    add_index :scaling_observations,
      [ :project_id, :created_at, :id ],
      name: "idx_scaling_observations_project_recent"
    add_index :scaling_observations,
      [ :project_id, :observation_type, :created_at ],
      name: "idx_scaling_observations_project_type_created"
    add_index :scaling_observations,
      [ :project_id, :status, :created_at ],
      name: "idx_scaling_observations_project_status_created"
    add_index :scaling_observations,
      [ :issue_id, :created_at ],
      name: "idx_scaling_observations_issue_created"

    execute <<~SQL
      ALTER TABLE scaling_observations ENABLE ROW LEVEL SECURITY;
      ALTER TABLE scaling_observations FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON scaling_observations
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = scaling_observations.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = scaling_observations.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON scaling_observations"
    execute "ALTER TABLE scaling_observations NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE scaling_observations DISABLE ROW LEVEL SECURITY"

    drop_table :scaling_observations
  end
end
