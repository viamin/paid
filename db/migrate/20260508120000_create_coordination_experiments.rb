# frozen_string_literal: true

class CreateCoordinationExperiments < ActiveRecord::Migration[8.1]
  def change
    create_table :coordination_experiments, comment: "Workflow-scoped A/B tests for feature orchestration coordination policies" do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.string :policy_name, null: false, default: "feature_orchestration", comment: "Coordination policy family under test"
      t.string :status, null: false, default: "draft"
      t.jsonb :control_policy, null: false, default: {}, comment: "Baseline coordination policy configuration"
      t.integer :min_samples_per_variant, null: false, default: 10
      t.integer :traffic_percentage, null: false, default: 100
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    create_table :coordination_experiment_variants, comment: "Individual policy arms within a coordination experiment" do |t|
      t.references :coordination_experiment, null: false, foreign_key: { on_delete: :cascade }
      t.jsonb :policy_config, null: false, default: {}, comment: "Effective policy config for this variant"
      t.boolean :is_control, null: false, default: false
      t.integer :sample_count, null: false, default: 0
      t.decimal :total_coordination_score, precision: 10, scale: 4, null: false, default: 0
      t.decimal :avg_coordination_score, precision: 5, scale: 4

      t.timestamps
    end

    create_table :coordination_experiment_assignments, comment: "Assignment and outcome for one feature orchestration workflow sample" do |t|
      t.references :coordination_experiment, null: false, foreign_key: { on_delete: :cascade }
      t.references :coordination_experiment_variant, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :issue, foreign_key: { on_delete: :nullify }
      t.string :workflow_id, null: false, comment: "Temporal workflow ID for the orchestrated feature sample"
      t.string :outcome_status, null: false, default: "assigned"
      t.decimal :coordination_score, precision: 5, scale: 4
      t.jsonb :outcome_metrics, null: false, default: {}, comment: "Aggregated coordination quality and cost metrics"

      t.timestamps
    end

    add_reference :coordination_experiments,
      :winner_variant,
      foreign_key: { to_table: :coordination_experiment_variants, on_delete: :nullify },
      index: true

    add_index :coordination_experiments, [ :account_id, :policy_name, :status ],
      name: "idx_coordination_experiments_account_policy_status"
    add_index :coordination_experiments, [ :account_id, :policy_name ],
      unique: true,
      where: "status = 'running'",
      name: "idx_coordination_experiments_one_running_policy"
    add_index :coordination_experiment_variants, [ :coordination_experiment_id, :is_control ],
      unique: true,
      where: "is_control = true",
      name: "idx_coordination_experiment_variants_one_control"
    add_index :coordination_experiment_assignments, [ :coordination_experiment_id, :workflow_id ],
      unique: true,
      name: "idx_coordination_experiment_assignments_unique"
  end
end
