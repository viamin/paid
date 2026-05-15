# frozen_string_literal: true

module MarketplaceEntries
  class InjectIntoPrompt
    def initialize(agent_run:, prompt:)
      @agent_run = agent_run
      @prompt = prompt
    end

    def self.call(...)
      new(...).call
    end

    def call
      sections = []
      non_prompt_strategies = []

      @agent_run.agent_run_marketplace_entries.includes(:marketplace_entry).ordered.each do |attachment|
        strategy = attachment.rendered_payload["attachment_strategy"]

        if MarketplaceEntries::Renderer.prompt_only?(strategy)
          payload = attachment.rendered_payload["payload"]
          body = payload["content"] || payload["body"] || JSON.pretty_generate(payload)
          sections << <<~SECTION.strip
            ## Marketplace: #{attachment.marketplace_entry.name}

            Source: #{attachment.attachment_source.humanize}
            Why attached: #{attachment.selection_reason}

            #{body}
          SECTION
        else
          non_prompt_strategies << "#{attachment.marketplace_entry.name} (#{strategy})"
        end
      end

      if non_prompt_strategies.any?
        Rails.logger.info(
          message: "marketplace_entries.non_prompt_strategies_skipped",
          agent_run_id: @agent_run.id,
          strategies: non_prompt_strategies,
          note: "MCP server, plugin, and provider_config strategies are persisted but not yet wired into the runtime prompt path"
        )
      end

      return @prompt if sections.empty?

      base = @prompt.to_s.rstrip
      attachments = "# Marketplace Attachments\n\n#{sections.join("\n\n")}"

      base.empty? ? attachments : "#{base}\n\n#{attachments}"
    end
  end
end
