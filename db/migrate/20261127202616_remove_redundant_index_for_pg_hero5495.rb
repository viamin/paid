# frozen_string_literal: true

# index_config_experiment_variants_on_experiment_and_control covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5495 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :configuration_experiment_variants, name: "idx_on_configuration_experiment_id_54cb3ed654", algorithm: :concurrently
  end

  def down
    add_index :configuration_experiment_variants, [ :configuration_experiment_id ],
      name: "idx_on_configuration_experiment_id_54cb3ed654", algorithm: :concurrently
  end
end
