# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-006
class AddAgentRunLifecycleSyncEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :agent_run_lifecycle_sync_enabled, :boolean, null: false, default: true,
      comment: "Whether agent-run-driven lifecycle writes push to the mapped provider, independent of the general lifecycle-mapping sync."
  end
end
