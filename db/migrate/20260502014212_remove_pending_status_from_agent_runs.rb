class RemovePendingStatusFromAgentRuns < ActiveRecord::Migration[8.1]
  def up
    AgentRun.where(status: "pending").where.not(temporal_workflow_id: nil)
            .update_all(status: "queued")

    AgentRun.where(status: "pending")
            .update_all("status = 'queued', temporal_workflow_id = 'claimed'")
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
