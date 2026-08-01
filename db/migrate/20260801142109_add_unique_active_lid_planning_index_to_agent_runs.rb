# frozen_string_literal: true

class AddUniqueActiveLidPlanningIndexToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :agent_runs, :project_id,
      unique: true,
      where: "goal = 'lid_planning' AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_lid_planning",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_lid_planning",
      algorithm: :concurrently,
      if_exists: true
  end
end
