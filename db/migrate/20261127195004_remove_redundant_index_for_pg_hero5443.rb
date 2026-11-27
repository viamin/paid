# frozen_string_literal: true

# idx_coordination_signals_target_type covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5443 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_coordination_signals, name: "index_agent_coordination_signals_on_target_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :agent_coordination_signals, [ :target_agent_run_id ],
      name: "index_agent_coordination_signals_on_target_agent_run_id", algorithm: :concurrently
  end
end
