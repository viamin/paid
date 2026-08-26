# frozen_string_literal: true

module Models
  # Seeds LlmModel records from the RubyLLM registry, falling back to the
  # app snapshot for app-owned defaults and registry failures.
  class SeedKnownModels
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
        model_id: "claude-sonnet-5",
        display_name: "Claude Sonnet 5",
        provider: "anthropic",
        family: "claude-5",
        category: "coding",
        context_window: 200_000,
        max_output_tokens: 64_000,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.2,
        tier: "mid"
      },
      {
        model_id: "claude-opus-4-7",
        display_name: "Claude Opus 4.7",
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
        model_id: "claude-fable-5",
        display_name: "Claude Fable 5",
        provider: "anthropic",
        family: "claude-4",
        category: "general",
        context_window: 200_000,
        max_output_tokens: 32_000,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.5,
        tier: "mid"
      },
      {
        model_id: "claude-opus-4-8",
        display_name: "Claude Opus 4.8",
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
        model_id: "claude-opus-5",
        display_name: "Claude Opus 5",
        provider: "anthropic",
        family: "claude-5",
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
        model_id: "gpt-5.1",
        display_name: "GPT-5.1",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.25,
        output_cost_per_million: 10.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.0,
        tier: "mid"
      },
      {
        model_id: "gpt-5.2",
        display_name: "GPT-5.2",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.25,
        output_cost_per_million: 10.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.1,
        tier: "mid"
      },
      {
        model_id: "gpt-5.2-codex",
        display_name: "GPT-5.2 Codex",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 2.50,
        output_cost_per_million: 15.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.5,
        tier: "high"
      },
      {
        model_id: "gpt-5.2-pro",
        display_name: "GPT-5.2 Pro",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 5.0,
        output_cost_per_million: 20.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.5,
        tier: "high"
      },
      {
        model_id: "gpt-5.3-codex",
        display_name: "GPT-5.3 Codex",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.6,
        tier: "high",
        active: false
      },
      {
        model_id: "gpt-5.3-codex-spark",
        display_name: "GPT-5.3 Codex Spark",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.50,
        output_cost_per_million: 8.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.8,
        tier: "mid"
      },
      {
        model_id: "gpt-5.4",
        display_name: "GPT-5.4",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.25,
        output_cost_per_million: 10.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.3,
        tier: "mid"
      },
      {
        model_id: "gpt-5.4-mini",
        display_name: "GPT-5.4 Mini",
        provider: "openai",
        family: "gpt-5",
        category: "general",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 0.25,
        output_cost_per_million: 2.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 7.3,
        tier: "low"
      },
      {
        model_id: "gpt-5.4-nano",
        display_name: "GPT-5.4 Nano",
        provider: "openai",
        family: "gpt-5",
        category: "general",
        context_window: 400_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.10,
        output_cost_per_million: 0.50,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 6.8,
        tier: "low"
      },
      {
        model_id: "gpt-5.4-pro",
        display_name: "GPT-5.4 Pro",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 5.0,
        output_cost_per_million: 20.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.6,
        tier: "high"
      },
      {
        model_id: "gpt-5.5",
        display_name: "GPT-5.5",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 2.50,
        output_cost_per_million: 12.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.8,
        tier: "high"
      },
      {
        model_id: "gpt-5.5-pro",
        display_name: "GPT-5.5 Pro",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 10.0,
        output_cost_per_million: 30.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 10.0,
        tier: "high",
        active: false
      },
      {
        model_id: "gpt-5.6",
        display_name: "GPT-5.6",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.50,
        output_cost_per_million: 12.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.4,
        tier: "mid",
        active: false
      },
      {
        model_id: "gpt-5.6-luna",
        display_name: "GPT-5.6 Luna",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.50,
        output_cost_per_million: 12.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.0,
        tier: "mid",
        active: false
      },
      {
        model_id: "gpt-5.6-sol",
        display_name: "GPT-5.6 Sol",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.50,
        output_cost_per_million: 12.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.0,
        tier: "mid",
        active: false
      },
      {
        model_id: "gpt-5.6-terra",
        display_name: "GPT-5.6 Terra",
        provider: "openai",
        family: "gpt-5",
        category: "coding",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.50,
        output_cost_per_million: 12.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.0,
        tier: "mid",
        active: false
      },
      {
        model_id: "gpt-5-mini",
        display_name: "GPT-5 Mini",
        provider: "openai",
        family: "gpt-5",
        category: "general",
        context_window: 400_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 0.25,
        output_cost_per_million: 2.0,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 7.0,
        tier: "low"
      },
      {
        model_id: "glm-5.2",
        display_name: "GLM-5.2",
        provider: "zai_coding",
        family: "glm-5",
        category: "coding",
        context_window: 1_000_000,
        max_output_tokens: 128_000,
        input_cost_per_million: 1.4,
        output_cost_per_million: 4.4,
        supports_vision: false,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.9,
        tier: "mid"
      },
      {
        model_id: "gemini-2.5-flash-lite",
        display_name: "Gemini 2.5 Flash Lite",
        provider: "google",
        family: "gemini-2",
        category: "general",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.10,
        output_cost_per_million: 0.40,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 7.0,
        tier: "low"
      },
      # gemini-live-2.5-flash is excluded: it is a Live API (WebSocket, real-time
      # bidirectional streaming) model and is not accessible via the standard
      # generateContent REST endpoint this catalog assumes. Cataloguing it would
      # cause model selection to route agent runs there, which would fail at
      # execution. Re-evaluate if Google exposes it on the standard REST surface.
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
      },
      {
        model_id: "gemini-3.1-flash-lite",
        display_name: "Gemini 3.1 Flash Lite",
        provider: "google",
        family: "gemini-3",
        category: "general",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.10,
        output_cost_per_million: 0.40,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 7.2,
        tier: "low"
      },
      {
        model_id: "gemini-3.5-flash",
        display_name: "Gemini 3.5 Flash",
        provider: "google",
        family: "gemini-3",
        category: "general",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.30,
        output_cost_per_million: 1.50,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.2,
        tier: "mid"
      },
      {
        model_id: "gemini-3.5-flash-lite",
        display_name: "Gemini 3.5 Flash Lite",
        provider: "google",
        family: "gemini-3",
        category: "general",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.10,
        output_cost_per_million: 0.40,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 7.3,
        tier: "low"
      },
      {
        model_id: "gemini-3.6-flash",
        display_name: "Gemini 3.6 Flash",
        provider: "google",
        family: "gemini-3",
        category: "general",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.30,
        output_cost_per_million: 1.50,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.3,
        tier: "mid"
      },
      {
        model_id: "gemini-3.7-flash",
        display_name: "Gemini 3.7 Flash",
        provider: "google",
        family: "gemini-3",
        category: "general",
        context_window: 1_000_000,
        max_output_tokens: 65_536,
        input_cost_per_million: 0.30,
        output_cost_per_million: 1.50,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 8.4,
        tier: "mid"
      },
      # Catalog completeness for the custom Anthropic-compatible MiniMax
      # direct-outbound endpoint: opencode/pi runners reference this row via
      # `Runner#direct_outbound_config_models_must_exist_in_catalog`. MiniMax is
      # not in the RubyLLM registry (intentionally excluded from
      # `Models::DetectCatalogDrift`), so — unlike the native
      # anthropic/openai/google rows — the registry merge never backfills
      # pricing/context here. Cost stays nil rather than guessed because it
      # feeds billing; populate once MiniMax publishes figures.
      {
        model_id: "MiniMax-M3",
        display_name: "MiniMax M3",
        provider: "minimax",
        family: "MiniMax",
        category: "coding",
        context_window: 1_000_000,
        max_output_tokens: 32_000,
        supports_vision: true,
        supports_tools: true,
        supports_json_output: true,
        capability_score: 9.0,
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
        model.active = snapshot_attrs.fetch(:active, true)
        model.save!
        synced += 1
      end

      retired = retire_stale_seeded_models

      TokenUsageTracker.clear_model_cache!
      Rails.logger.info(message: "model_registry.seed_completed", models_synced: synced, models_retired: retired)
      synced
    end

    private

    def retire_stale_seeded_models
      desired_ids = KNOWN_MODELS.filter_map { |attrs| attrs[:model_id] }
      retired = 0
      LlmModel.where(catalog_source: "seeded").where.not(model_id: desired_ids).active.find_each do |model|
        model.update!(active: false)
        retired += 1
      end
      retired
    end

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
      RegistryModels.fetch.grouped_by_id
    end

    def normalized_provider(provider)
      RegistryModels.normalized_provider(provider)
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
