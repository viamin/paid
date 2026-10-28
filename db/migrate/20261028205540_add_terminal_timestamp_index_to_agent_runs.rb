# frozen_string_literal: true

class AddTerminalTimestampIndexToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :agent_runs, "status, COALESCE(completed_at, updated_at)",
      name: "index_agent_runs_on_status_terminal_timestamp", algorithm: :concurrently
  end

  def down
    remove_index :agent_runs, name: "index_agent_runs_on_status_terminal_timestamp", algorithm: :concurrently
  end
end
