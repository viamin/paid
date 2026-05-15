# frozen_string_literal: true

module MarketplaceEntries
  class AttachToRun
    attr_reader :agent_run, :manual_entry_ids, :auto_attach_enabled

    def initialize(agent_run:, manual_entry_ids: nil, auto_attach_enabled: false)
      @agent_run = agent_run
      @manual_entry_ids = manual_entry_ids
      @auto_attach_enabled = auto_attach_enabled
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate_manual_entry_ids!
      results = Resolver.call(project: agent_run.project, agent_run:, manual_entry_ids:, auto_attach_enabled:)

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
      end

      agent_run.agent_run_marketplace_entries.ordered
    end

    private

    def validate_manual_entry_ids!
      selected_entry_ids = Array(manual_entry_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      return if selected_entry_ids.empty?

      unsupported_entries = agent_run.project.account.marketplace_entries
        .where(id: selected_entry_ids)
        .where.not(entry_type: MarketplaceEntry::PROMPT_COMPATIBLE_ENTRY_TYPES)
      return if unsupported_entries.empty?

      agent_run.errors.add(
        :base,
        "Only prompt-compatible marketplace entries can be attached to runs in this first pass: #{unsupported_entries.order(:name).pluck(:name).join(', ')}"
      )
      raise ActiveRecord::RecordInvalid, agent_run
    end

    def provider_key
      @provider_key ||= agent_run.provider&.provider_key || ProviderSupport.provider_key_for_agent_type(agent_run.agent_type)
    end
  end
end
