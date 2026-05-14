# frozen_string_literal: true

module MarketplaceEntries
  class InjectIntoPrompt
    def initialize(agent_run:, prompt:)
      @agent_run = agent_run
      @prompt = prompt.to_s
    end

    def self.call(...)
      new(...).call
    end

    def call
      sections = @agent_run.agent_run_marketplace_entries.includes(:marketplace_entry).ordered.filter_map do |attachment|
        next unless attachment.rendered_payload["attachment_strategy"] == "prompt_append"

        payload = attachment.rendered_payload["payload"]
        body = payload["content"] || payload["body"] || JSON.pretty_generate(payload)
        <<~SECTION.strip
          ## Marketplace: #{attachment.marketplace_entry.name}

          Source: #{attachment.attachment_source.humanize}
          Why attached: #{attachment.selection_reason}

          #{body}
        SECTION
      end

      return @prompt if sections.empty?

      "#{@prompt.rstrip}\n\n# Marketplace Attachments\n\n#{sections.join("\n\n")}"
    end
  end
end
