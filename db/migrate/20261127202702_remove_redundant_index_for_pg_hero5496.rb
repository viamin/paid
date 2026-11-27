# frozen_string_literal: true

# idx_on_account_id_config_key_status_a42f39cd2a covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5496 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :configuration_experiments, name: "index_configuration_experiments_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :configuration_experiments, [ :account_id ],
      name: "index_configuration_experiments_on_account_id", algorithm: :concurrently
  end
end
