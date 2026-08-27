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
    remove_index :execution_usages, name: "index_execution_usages_on_agent_run_id",
      algorithm: :concurrently, if_exists: true
    add_index :execution_usages, :agent_run_id,
      name: "index_execution_usages_on_agent_run_id_unique",
      unique: true,
      algorithm: :concurrently,
      if_not_exists: true
  end
end
