# frozen_string_literal: true

module MarketplaceEntries
  class RerenderForRun
    include McpSnapshotSync

    attr_reader :agent_run, :provider_key

    def initialize(agent_run:, provider_key: nil)
      @agent_run = agent_run
      @provider_key = provider_key.to_s.presence || default_provider_key
    end

    def self.call(...)
      new(...).call
    end

    def call
      # Keep attach-time rendered_payload snapshots immutable so
      # configuration bundle identity remains reproducible across retries.
      synchronize_mcp_snapshot!(provider_key: provider_key)
      attachments
    end

    private

    def attachments
      @attachments ||= agent_run.agent_run_marketplace_entries.includes(:marketplace_entry, :marketplace_entry_version).ordered
    end

    def default_provider_key
      agent_run.runner&.runner_key || RunnerSupport.runner_key_for_agent_type(agent_run.agent_type)
    end
  end
end
