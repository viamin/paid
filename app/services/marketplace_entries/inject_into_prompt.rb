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
      return @prompt unless marketplace_entries_attached?

      sections = []
      non_prompt_strategies = []

      attachments.includes(:marketplace_entry).ordered.each do |attachment|
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
          note: "Runtime-only marketplace attachments are applied outside the prompt path"
        )
      end

      return @prompt if sections.empty?

      base = @prompt.to_s.rstrip
      attachment_section = "# Marketplace Attachments\n\n#{sections.join("\n\n")}"

      base.empty? ? attachment_section : "#{base}\n\n#{attachment_section}"
    end

    private

    def attachments
      @attachments ||= @agent_run.agent_run_marketplace_entries
    end

    def marketplace_entries_attached?
      return attachments.any? if attachments.loaded?
      return attachments.exists? if attachments.respond_to?(:exists?)

      attachments.any?
    end
  end
end
