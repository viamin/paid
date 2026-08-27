# frozen_string_literal: true

# Shared catalog of (api_provider, model_id) pairs that direct-outbound test
# fixtures seed into the LlmModel catalog. Kept here so the factory layer
# (spec/factories/runners.rb, spec/factories/providers.rb) and the smoke
# helpers all reference a single source of truth; otherwise new entries have
# to be added in three places and inevitably drift.
module KnownDirectOutboundModels
  # Maps [api_provider, model_id] => catalog "provider" string used when
  # seeding the matching LlmModel row. The provider string must equal the
  # Runner::DIRECT_OUTBOUND_API_PROVIDERS service_type so the direct-outbound
  # catalog-membership validation passes for the seeded runner/provider.
  CATALOG = {
    [ "openrouter", "moonshotai/kimi-k2-0905" ] => "openrouter",
    [ "openrouter", "moonshotai/kimi-k2.5" ] => "openrouter",
    [ "openrouter", "moonshotai/kimi-k2" ] => "openrouter",
    [ "openrouter", "moonshotai/kimi-k2-0906" ] => "openrouter",
    [ "openrouter", "anthropic/claude-opus-4.1" ] => "openrouter",
    [ "anthropic", "claude-sonnet-4-20250514" ] => "anthropic",
    [ "anthropic", "claude-sonnet-4-5" ] => "anthropic",
    [ "anthropic", "claude-3-7-sonnet" ] => "anthropic",
    [ "anthropic", "anthropic/claude-opus-4" ] => "anthropic",
    [ "openai", "gpt-4o" ] => "openai",
    [ "openai", "gpt-5.5" ] => "openai",
    [ "inception", "mercury-2" ] => "inception",
    [ "deepseek", "deepseek-chat" ] => "deepseek",
    [ "minimax", "MiniMax-M2.7" ] => "minimax",
    [ "minimax", "MiniMax-M2.7-highspeed" ] => "minimax",
    [ "minimax", "MiniMax-M3" ] => "minimax",
    [ "zai_coding", "glm-5.1" ] => "zai_coding",
    [ "zai_coding", "glm-5.2" ] => "zai_coding",
    [ "zai", "glm-5.1-zai" ] => "zai"
  }.freeze

  module_function

  # Seeds a matching LlmModel row for the given (api_provider, model_id) pair
  # if one is present in CATALOG. Returns the LlmModel when seeded/found,
  # nil otherwise so callers can no-op when the pair is not a known fixture.
  #
  # The runner config may carry a provider-qualified id (e.g. "minimax/MiniMax-M3"
  # for OpenCode's prefixed model strings) while the catalog stores the bare id
  # ("MiniMax-M3"). Mirror the validation's candidate-stripping so the factory
  # seed lands on the same catalog row the validation looks up; otherwise
  # direct-outbound factory-built runners fail the new validation at save.
  def seed_catalog_model(api_provider:, model_id:)
    raw = model_id.to_s
    bare_id = raw.include?("/") ? raw.split("/", 2).last : raw
    matched = CATALOG.find { |(key_provider, key_model_id), _| key_provider == api_provider.to_s && [ bare_id, raw ].include?(key_model_id) }
    return nil if matched.nil?

    matched_id = matched.first.last
    provider = matched.last
    seed_model(model_id: matched_id, provider: provider)
  end

  # Seeds an LlmModel row directly with the given provider/service_type.
  # Used by smoke helpers that have already resolved the service type from
  # the runner/provider config rather than looking it up in CATALOG.
  def seed_model(model_id:, provider:)
    LlmModel.find_or_create_by!(model_id: model_id) do |model|
      model.display_name = model_id.to_s.split("/").last.tr("_-", " ").split.map(&:capitalize).join(" ")
      model.provider = provider
      model.category = "coding"
      model.tier = "mid"
      model.active = true
    end
  end

  # Seeds a matching LlmModel row for a direct-outbound Runner or Provider
  # factory build by reading (api_provider, model) out of the record's config
  # hash. Returns nil when the runner_key is not a direct-outbound runner, the
  # config is missing the relevant nested block, or the (api_provider, model)
  # pair is not in CATALOG.
  #
  # Centralizes the seed step shared by spec/factories/runners.rb and
  # spec/factories/providers.rb so the factories stay in lock-step with the
  # catalog validation added in Runner#direct_outbound_config_models_must_exist_in_catalog.
  def seed_from_direct_outbound_config(record)
    config_key, model_key = case record.runner_key
    when "opencode", "kilocode", "pi", "omp"
      [ record.runner_key, "model" ]
    else
      return
    end

    config = record.config.is_a?(Hash) ? record.config[config_key] : nil
    return unless config.is_a?(Hash)

    api_provider = record.provider_api_key&.api_service_type.to_s.presence || config["api_provider"].to_s
    model_id = config[model_key].to_s
    return if api_provider.blank? || model_id.blank?

    seed_catalog_model(api_provider: api_provider, model_id: model_id)
  end
end
