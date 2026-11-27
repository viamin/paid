# frozen_string_literal: true

# index_decomposition_decisions_on_project_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5515 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :decomposition_decisions, name: "index_decomposition_decisions_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :decomposition_decisions, [ :project_id ],
      name: "index_decomposition_decisions_on_project_id", algorithm: :concurrently
  end
end
