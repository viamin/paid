# frozen_string_literal: true

# index_agent_run_phases_on_agent_run_id_and_started_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5452 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_run_phases, name: "index_agent_run_phases_on_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :agent_run_phases, [ :agent_run_id ],
      name: "index_agent_run_phases_on_agent_run_id", algorithm: :concurrently
  end
end
