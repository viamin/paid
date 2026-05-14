# frozen_string_literal: true

module MarketplaceEntries
  class Renderer
    attr_reader :entry, :version, :provider_key

    def initialize(entry:, version:, provider_key:)
      @entry = entry
      @version = version
      @provider_key = provider_key.to_s
    end

    def self.call(...)
      new(...).call
    end

    def call
      artifact = selected_renderer.deep_dup
      {
        "provider" => provider_key,
        "provider_format" => artifact.delete("provider_format") || artifact.delete("format") || entry.provider_format,
        "attachment_strategy" => artifact.delete("attachment_strategy") || inferred_attachment_strategy,
        "payload" => artifact
      }
    end

    private

    def selected_renderer
      version.renderers[provider_key] || version.renderers["default"] || version.canonical_artifact
    end

    def inferred_attachment_strategy
      return "mcp_server" if entry.entry_type == "mcp_server"
      return "runtime_config" if entry.entry_type.in?(%w[plugin provider_config])

      "prompt_append"
    end

    STRATEGIES_PROMPT_ONLY = Set.new(%w[prompt_append]).freeze

    def self.prompt_only?(strategy)
      STRATEGIES_PROMPT_ONLY.include?(strategy)
    end
  end
end
