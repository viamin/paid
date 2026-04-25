# frozen_string_literal: true

class CreateConfigurationExperiments < ActiveRecord::Migration[8.1]
  def change
    create_table :configuration_experiments do |t|
      t.references :account, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.string :config_key, null: false
      t.string :status, limit: 50, null: false, default: "draft"
      t.text :control_value, null: false
      t.string :experiment_type, limit: 50, null: false
      t.integer :min_samples_per_variant, null: false, default: 30
      t.decimal :confidence_threshold, precision: 5, scale: 4, null: false, default: 0.95
      t.integer :traffic_percentage, null: false, default: 100
      t.jsonb :cached_analysis
      t.string :analysis_samples_key
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    create_table :configuration_experiment_variants do |t|
      t.references :configuration_experiment, null: false, foreign_key: { on_delete: :cascade }
      t.text :config_value, null: false
      t.boolean :is_control, null: false, default: false
      t.integer :sample_count, null: false, default: 0
      t.decimal :total_quality_score, precision: 10, scale: 4, null: false, default: 0
      t.decimal :avg_quality_score, precision: 5, scale: 4

      t.timestamps
    end

    create_table :configuration_experiment_assignments do |t|
      t.references :configuration_experiment, null: false, foreign_key: { on_delete: :cascade }
      t.references :configuration_experiment_variant, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.decimal :quality_score, precision: 5, scale: 4

      t.timestamps
    end

    add_reference :configuration_experiments,
      :winner_variant,
      foreign_key: { to_table: :configuration_experiment_variants, on_delete: :nullify },
      index: true

    add_index :configuration_experiments, [ :account_id, :config_key, :status ]
    add_index :configuration_experiments,
      [ :account_id, :config_key ],
      unique: true,
      where: "status = 'running' AND account_id IS NOT NULL",
      name: "index_config_experiments_one_running_per_account_key"
    add_index :configuration_experiments,
      :config_key,
      unique: true,
      where: "status = 'running' AND account_id IS NULL",
      name: "index_global_config_experiments_one_running_per_key"
    add_index :configuration_experiment_variants,
      [ :configuration_experiment_id, :is_control ],
      name: "index_config_experiment_variants_on_experiment_and_control"
    add_index :configuration_experiment_variants,
      :configuration_experiment_id,
      unique: true,
      where: "is_control = true",
      name: "index_config_experiment_variants_one_control"
    add_index :configuration_experiment_assignments,
      [ :configuration_experiment_id, :agent_run_id ],
      unique: true,
      name: "index_config_experiment_assignments_unique"
  end
end
