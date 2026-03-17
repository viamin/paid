# frozen_string_literal: true

module Models
  # Seeds LlmModel records from a hardcoded snapshot of known models.
  # Despite the class name, this does NOT pull from the ruby-llm
  # registry at runtime — pricing and capabilities are static.
  # TODO(#139): Integrate with ruby-llm registry as the primary source,
  # falling back to KNOWN_MODELS when the registry is unavailable.
  class SyncFromRegistry
    KNOWN_MODELS = [
      {
        model_id: "claude-sonnet-4-6",
        display_name: "Claude Sonnet 4.6",
        provider: "anthropic",
        family: "claude-4",
        category: "coding",
        context_window: 200_000,
        max_output_tokens: 64_000,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.0
      },
      {
        model_id: "claude-opus-4-6",
        display_name: "Claude Opus 4.6",
        provider: "anthropic",
        family: "claude-4",
        category: "coding",
        context_window: 200_000,
        max_output_tokens: 32_000,
        input_cost_per_million: 15.0,
        output_cost_per_million: 75.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 10.0
      },
      {
        model_id: "claude-haiku-4-5-20251001",
        display_name: "Claude Haiku 4.5",
        provider: "anthropic",
        family: "claude-4",
        category: "general",
        context_window: 200_000,
        max_output_tokens: 8_192,
        input_cost_per_million: 0.80,
        output_cost_per_million: 4.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 7.0
      },
      {
        model_id: "gpt-4o",
        display_name: "GPT-4o",
        provider: "openai",
        family: "gpt-4",
        category: "coding",
        context_window: 128_000,
        max_output_tokens: 16_384,
        input_cost_per_million: 2.50,
        output_cost_per_million: 10.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.5
      },
      {
        model_id: "gpt-4o-mini",
        display_name: "GPT-4o Mini",
        provider: "openai",
        family: "gpt-4",
        category: "general",
        context_window: 128_000,
        max_output_tokens: 16_384,
        input_cost_per_million: 0.15,
        output_cost_per_million: 0.60,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 6.5
      },
      {
        model_id: "gemini-2.5-pro",
        display_name: "Gemini 2.5 Pro",
        provider: "google",
        family: "gemini-2",
        category: "coding",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 1.25,
        output_cost_per_million: 10.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.0
      }
    ].freeze

    def self.call
      new.call
    end

    def call
      synced = 0
      KNOWN_MODELS.each do |attrs|
        model = LlmModel.find_or_initialize_by(model_id: attrs[:model_id])
        model.assign_attributes(attrs)
        model.save!
        synced += 1
      end

      Rails.logger.info(message: "model_registry.sync_completed", models_synced: synced)
      synced
    end
  end
end
