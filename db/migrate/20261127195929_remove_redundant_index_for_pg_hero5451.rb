# frozen_string_literal: true

# index_agent_run_marketplace_entries_on_run_source_position covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5451 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_run_marketplace_entries, name: "index_agent_run_marketplace_entries_on_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :agent_run_marketplace_entries, [ :agent_run_id ],
      name: "index_agent_run_marketplace_entries_on_agent_run_id", algorithm: :concurrently
  end
end
