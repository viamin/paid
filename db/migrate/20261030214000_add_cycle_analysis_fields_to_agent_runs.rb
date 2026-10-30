# frozen_string_literal: true

class AddCycleAnalysisFieldsToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec AUTO-PICK-QUEUE-016
  def change
    add_index :agent_runs, [ :project_id, :goal, :status ], name: "index_agent_runs_cycle_analysis_lookup",
      algorithm: :concurrently
  end
end
