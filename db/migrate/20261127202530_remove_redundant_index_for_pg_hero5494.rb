# frozen_string_literal: true

# index_config_experiment_assignments_unique covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5494 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :configuration_experiment_assignments, name: "idx_on_configuration_experiment_id_6532d1a5ed", algorithm: :concurrently
  end

  def down
    add_index :configuration_experiment_assignments, [ :configuration_experiment_id ],
      name: "idx_on_configuration_experiment_id_6532d1a5ed", algorithm: :concurrently
  end
end
