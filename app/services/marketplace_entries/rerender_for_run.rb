# frozen_string_literal: true

module MarketplaceEntries
  class RerenderForRun
    attr_reader :agent_run, :provider_key

    def initialize(agent_run:, provider_key: nil)
      @agent_run = agent_run
      @provider_key = provider_key.to_s.presence || default_provider_key
    end

    def self.call(...)
      new(...).call
    end

    def call
      AgentRunMarketplaceEntry.transaction do
        attachments.each do |attachment|
          rendered = Renderer.call(
            entry: attachment.marketplace_entry,
            version: attachment.marketplace_entry_version,
            provider_key: provider_key
          )

          attachment.update!(
            rendered_format: rendered.fetch("provider_format"),
            rendered_payload: rendered
          )
        end

        synchronize_mcp_snapshot!
      end

      agent_run.agent_run_marketplace_entries.ordered
    end

    private

    def attachments
      @attachments ||= agent_run.agent_run_marketplace_entries.includes(:marketplace_entry, :marketplace_entry_version).ordered
    end

    def default_provider_key
      agent_run.provider&.provider_key || ProviderSupport.provider_key_for_agent_type(agent_run.agent_type)
    end

    def synchronize_mcp_snapshot!
      base_snapshot = Array(agent_run.mcp_server_snapshot).reject { |snapshot| snapshot["marketplace_attachment"] == true }
      attachment_snapshots = RuntimeAttachments.mcp_server_snapshots(agent_run)
      merged_snapshot = base_snapshot + attachment_snapshots
      return if merged_snapshot == agent_run.mcp_server_snapshot

      agent_run.update_columns(mcp_server_snapshot: merged_snapshot)
      agent_run.mcp_server_snapshot = merged_snapshot
    end
  end
end
