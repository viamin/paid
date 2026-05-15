# frozen_string_literal: true

module MarketplaceEntries
  class AttachToRun
    include McpSnapshotSync

    attr_reader :agent_run, :manual_entry_ids, :auto_attach_enabled, :account_auto_attach_required

    def initialize(agent_run:, manual_entry_ids: nil, auto_attach_enabled: false, account_auto_attach_required: false)
      @agent_run = agent_run
      @manual_entry_ids = manual_entry_ids
      @auto_attach_enabled = auto_attach_enabled
      @account_auto_attach_required = account_auto_attach_required
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
        account_auto_attach_required:
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
  end
end
