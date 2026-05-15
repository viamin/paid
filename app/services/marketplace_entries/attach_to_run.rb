# frozen_string_literal: true

module MarketplaceEntries
  class AttachToRun
    attr_reader :agent_run, :manual_entry_ids, :auto_attach_enabled, :consent_owner_id

    def initialize(agent_run:, manual_entry_ids: nil, auto_attach_enabled: false, consent_owner_id: nil)
      @agent_run = agent_run
      @manual_entry_ids = manual_entry_ids
      @auto_attach_enabled = auto_attach_enabled
      @consent_owner_id = consent_owner_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      results = Resolver.call(
        project: agent_run.project,
        agent_run:,
        manual_entry_ids:,
        auto_attach_enabled:,
        consent_owner_id:
      )

      AgentRunMarketplaceEntry.transaction do
        agent_run.agent_run_marketplace_entries.delete_all
        results.each_with_index do |result, index|
          rendered = Renderer.call(
            entry: result.entry,
            version: result.version,
            provider_key: provider_key
          )

          agent_run.agent_run_marketplace_entries.create!(
            marketplace_entry: result.entry,
            marketplace_entry_version: result.version,
            attachment_source: result.source,
            position: index,
            selection_reason: result.reason,
            rendered_format: rendered.fetch("provider_format"),
            rendered_payload: rendered
          )
        end

        synchronize_mcp_snapshot!
      end

      agent_run.agent_run_marketplace_entries.ordered
    end

    private

    def provider_key
      @provider_key ||= agent_run.provider&.provider_key || ProviderSupport.provider_key_for_agent_type(agent_run.agent_type)
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
