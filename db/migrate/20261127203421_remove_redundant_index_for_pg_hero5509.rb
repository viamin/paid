# frozen_string_literal: true

# idx_coordination_policies_project_type_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5509 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :coordination_policies, name: "index_coordination_policies_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :coordination_policies, [ :project_id ],
      name: "index_coordination_policies_on_project_id", algorithm: :concurrently
  end
end
