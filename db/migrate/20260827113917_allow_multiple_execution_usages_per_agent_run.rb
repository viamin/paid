# frozen_string_literal: true

class AllowMultipleExecutionUsagesPerAgentRun < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :execution_usages, name: "index_execution_usages_on_agent_run_id_unique",
      algorithm: :concurrently, if_exists: true
    add_index :execution_usages, :agent_run_id,
      name: "index_execution_usages_on_agent_run_id",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Cannot restore the unique index on execution_usages.agent_run_id once a run has " \
      "accumulated more than one execution_usages row (multi-cycle behavior enabled by this " \
      "migration). Deduplicate execution_usages per agent_run_id before attempting rollback."
  end
end
