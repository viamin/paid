# frozen_string_literal: true

module MarketplaceEntries
  module McpSnapshotSync
    private

    def synchronize_mcp_snapshot!(provider_key: nil)
      base_snapshot = Array(agent_run.mcp_server_snapshot).reject { |snapshot| snapshot["marketplace_attachment"] == true }
      attachment_snapshots = RuntimeAttachments.mcp_server_snapshots(agent_run, provider_key: provider_key)
      merged_snapshot = base_snapshot + attachment_snapshots
      return if merged_snapshot == agent_run.mcp_server_snapshot

      # AgentRun marks the creation-time snapshot as readonly, so persistence
      # must bypass instance-level update APIs that enforce readonly guards.
      agent_run.class.where(id: agent_run.id).update_all(mcp_server_snapshot: merged_snapshot)
      agent_run.mcp_server_snapshot = merged_snapshot
    end
  end
end
