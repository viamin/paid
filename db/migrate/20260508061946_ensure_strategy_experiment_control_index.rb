# frozen_string_literal: true

class EnsureStrategyExperimentControlIndex < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS index_strategy_experiment_variants_one_control
      ON strategy_experiment_variants (strategy_experiment_id)
      WHERE is_control = true
    SQL
  end

  def down
    remove_index :strategy_experiment_variants, name: :index_strategy_experiment_variants_one_control, if_exists: true
  end
end
