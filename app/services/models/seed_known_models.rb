# frozen_string_literal: true

module Models
  # Seeds LlmModel records from the RubyLLM registry, falling back to the
  # app snapshot for app-owned defaults and registry failures.
  class SeedKnownModels
    REGISTRY_PROVIDER_ALIASES = {
      "gemini" => "google"
    }.freeze
    TOOL_CAPABILITIES = %w[function_calling tools].freeze
    JSON_OUTPUT_CAPABILITIES = %w[structured_output json_output].freeze

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
        capability_score: 9.0,
        tier: "mid"
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
        capability_score: 10.0,
        tier: "high"
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
        capability_score: 7.0,
        tier: "low"
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
        capability_score: 8.5,
        tier: "mid"
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
        capability_score: 6.5,
        tier: "low"
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
        capability_score: 8.0,
        tier: "mid"
      }
    ].freeze

    def self.call
      new.call
    end

    def call
      synced = 0
      registry_models = registry_models_by_id

      KNOWN_MODELS.each do |snapshot_attrs|
        model = LlmModel.find_or_initialize_by(model_id: snapshot_attrs[:model_id])
        model.assign_attributes(merged_attributes(snapshot_attrs, registry_models))
        model.tier ||= snapshot_attrs[:tier]
        model.save!
        synced += 1
      end

      TokenUsageTracker.clear_model_cache!
      Rails.logger.info(message: "model_registry.seed_completed", models_synced: synced)
      synced
    end

    private

    def merged_attributes(snapshot_attrs, registry_models)
      snapshot_attrs.except(:tier).merge(registry_attributes_for(snapshot_attrs, registry_models).compact)
    end

    def registry_attributes_for(snapshot_attrs, registry_models)
      registry_model = registry_model_for(snapshot_attrs, registry_models)
      return {} unless registry_model

      capabilities = Array(registry_model.capabilities).map(&:to_s)

      {
        display_name: registry_model.name,
        provider: normalized_provider(registry_model.provider),
        family: registry_model.family,
        context_window: registry_model.context_window,
        max_output_tokens: registry_model.max_output_tokens,
        input_cost_per_million: pricing_for(registry_model, :input_per_million),
        output_cost_per_million: pricing_for(registry_model, :output_per_million),
        supports_vision: supports_vision?(registry_model, capabilities),
        supports_tools: supports_tools?(capabilities),
        supports_json_output: supports_json_output?(capabilities)
      }
    end

    def registry_model_for(snapshot_attrs, registry_models)
      provider_models = registry_models[snapshot_attrs[:model_id]]
      return unless provider_models

      provider_models[normalized_provider(snapshot_attrs[:provider])] || provider_models.values.first
    end

    def registry_models_by_id
      models = fetch_registry_models
      return {} unless models

      models.each_with_object({}) do |model, index|
        next if model.id.blank?

        index[model.id] ||= {}
        index[model.id][normalized_provider(model.provider)] ||= model
      end
    end

    def fetch_registry_models
      require "ruby_llm"

      RubyLLM.models.refresh!
      models = Array(RubyLLM.models.all)
      return models if models.any?

      log_registry_fallback(reason: "empty_registry")
      nil
    rescue LoadError, StandardError => e
      log_registry_fallback(
        reason: "registry_unavailable",
        error_class: e.class.name,
        error_message: e.message
      )
      nil
    end

    def log_registry_fallback(reason:, error_class: nil, error_message: nil)
      Rails.logger.warn(
        message: "model_registry.registry_fallback",
        registry: "ruby_llm",
        reason: reason,
        fallback: "known_models",
        error_class: error_class,
        error_message: error_message
      )
    end

    def normalized_provider(provider)
      REGISTRY_PROVIDER_ALIASES.fetch(provider.to_s, provider.to_s)
    end

    def pricing_for(model, field)
      model.pricing.to_h.dig(:text_tokens, :standard, field)
    end

    def supports_vision?(model, capabilities)
      return true if capabilities.include?("vision")

      model.modalities.to_h.fetch(:input, []).intersect?(%w[image video pdf])
    end

    def supports_tools?(capabilities)
      (capabilities & TOOL_CAPABILITIES).any?
    end

    def supports_json_output?(capabilities)
      (capabilities & JSON_OUTPUT_CAPABILITIES).any?
    end
  end
end
