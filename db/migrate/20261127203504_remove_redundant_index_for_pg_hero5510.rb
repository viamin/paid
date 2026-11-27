# frozen_string_literal: true

# idx_coordination_policy_versions_policy_status_created covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5510 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :coordination_policy_versions, name: "index_coordination_policy_versions_on_coordination_policy_id", algorithm: :concurrently
  end

  def down
    add_index :coordination_policy_versions, [ :coordination_policy_id ],
      name: "index_coordination_policy_versions_on_coordination_policy_id", algorithm: :concurrently
  end
end
