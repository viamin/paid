# frozen_string_literal: true

class RemoveRedundantExperimentAndBundleIndexes < ActiveRecord::Migration[8.1]
  def up
    drop_index "index_configuration_bundle_outcomes_on_configuration_bundle_id"
    drop_index "index_strategy_experiments_on_account_id"
    drop_index "index_strategy_experiment_variants_on_strategy_experiment_id"
    drop_index "idx_on_strategy_experiment_id_c7c524095e"
  end

  def down
    add_index :configuration_bundle_outcomes, :configuration_bundle_id,
      name: :index_configuration_bundle_outcomes_on_configuration_bundle_id,
      if_not_exists: true
    add_index :strategy_experiments, :account_id,
      name: :index_strategy_experiments_on_account_id,
      if_not_exists: true
    add_index :strategy_experiment_variants, :strategy_experiment_id,
      name: :index_strategy_experiment_variants_on_strategy_experiment_id,
      if_not_exists: true
    add_index :strategy_experiment_assignments, :strategy_experiment_id,
      name: :idx_on_strategy_experiment_id_c7c524095e,
      if_not_exists: true
  end

  private

  def drop_index(name)
    execute "DROP INDEX IF EXISTS #{quote_column_name(name)}"
  end
end
