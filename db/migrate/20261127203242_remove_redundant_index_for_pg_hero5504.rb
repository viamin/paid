# frozen_string_literal: true

# idx_coordination_experiments_account_policy_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5504 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :coordination_experiments, name: "index_coordination_experiments_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :coordination_experiments, [ :account_id ],
      name: "index_coordination_experiments_on_account_id", algorithm: :concurrently
  end
end
