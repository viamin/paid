# frozen_string_literal: true

class CreateStrategyExperiments < ActiveRecord::Migration[8.1]
  def change
    create_table :strategy_experiments, comment: "A/B tests comparing evolved automation strategy variants against a baseline" do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.string :strategy_name, limit: 100, null: false, comment: "Automation strategy being tested (e.g. auto_pick, auto_review)"
      t.string :status, limit: 50, null: false, default: "draft"
      t.text :control_config, null: false, comment: "JSON-encoded baseline configuration for the strategy"
      t.integer :min_samples_per_variant, null: false, default: 30
      t.decimal :confidence_threshold, precision: 5, scale: 4, null: false, default: 0.95
      t.integer :traffic_percentage, null: false, default: 100
      t.jsonb :cached_analysis
      t.string :analysis_samples_key
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    create_table :strategy_experiment_variants, comment: "Individual variant arms within a strategy A/B test" do |t|
      t.references :strategy_experiment, null: false, foreign_key: { on_delete: :cascade }
      t.text :strategy_config, null: false, comment: "JSON-encoded configuration for this variant"
      t.boolean :is_control, null: false, default: false
      t.integer :sample_count, null: false, default: 0
      t.decimal :total_quality_score, precision: 10, scale: 4, null: false, default: 0
      t.decimal :avg_quality_score, precision: 5, scale: 4

      t.timestamps
    end

    create_table :strategy_experiment_assignments, comment: "Maps each agent run to the strategy variant it was assigned" do |t|
      t.references :strategy_experiment, null: false, foreign_key: { on_delete: :cascade }
      t.references :strategy_experiment_variant, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.decimal :quality_score, precision: 5, scale: 4

      t.timestamps
    end

    add_reference :strategy_experiments,
      :winner_variant,
      foreign_key: { to_table: :strategy_experiment_variants, on_delete: :nullify },
      index: true

    add_index :strategy_experiments, [ :account_id, :strategy_name, :status ],
      name: "index_strategy_experiments_on_account_strategy_status"
    add_index :strategy_experiments,
      [ :account_id, :strategy_name ],
      unique: true,
      where: "status = 'running'",
      name: "index_strategy_experiments_one_running_per_account_strategy"
    add_index :strategy_experiment_variants,
      [ :strategy_experiment_id, :is_control ],
      name: "index_strategy_experiment_variants_on_experiment_control"
    add_index :strategy_experiment_variants,
      :strategy_experiment_id,
      unique: true,
      where: "is_control = true",
      name: "index_strategy_experiment_variants_one_control"
    add_index :strategy_experiment_assignments,
      [ :strategy_experiment_id, :agent_run_id ],
      unique: true,
      name: "index_strategy_experiment_assignments_unique"
  end
end
