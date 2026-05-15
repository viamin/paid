# frozen_string_literal: true

module MarketplaceEntries
  module McpSnapshotSync
    private

    def synchronize_mcp_snapshot!(provider_key: nil)
      base_snapshot = Array(agent_run.mcp_server_snapshot).reject { |snapshot| snapshot["marketplace_attachment"] == true }
      attachment_snapshots = RuntimeAttachments.mcp_server_snapshots(agent_run, provider_key: provider_key)
      merged_snapshot = base_snapshot + attachment_snapshots
      return if merged_snapshot == agent_run.mcp_server_snapshot

      agent_run.update_columns(mcp_server_snapshot: merged_snapshot)
      agent_run.mcp_server_snapshot = merged_snapshot
    end
  end
end
