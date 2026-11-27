# frozen_string_literal: true

# idx_coordination_experiment_assignments_unique covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5503 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :coordination_experiment_assignments, name: "idx_on_coordination_experiment_id_73eaaefa30", algorithm: :concurrently
  end

  def down
    add_index :coordination_experiment_assignments, [ :coordination_experiment_id ],
      name: "idx_on_coordination_experiment_id_73eaaefa30", algorithm: :concurrently
  end
end
