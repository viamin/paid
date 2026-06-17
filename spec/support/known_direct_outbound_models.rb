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
    [ "zai_coding", "glm-5.1" ] => "zai_coding",
    [ "zai", "glm-5.1" ] => "zai"
  }.freeze

  module_function

  # Seeds a matching LlmModel row for the given (api_provider, model_id) pair
  # if one is present in CATALOG. Returns the LlmModel when seeded/found,
  # nil otherwise so callers can no-op when the pair is not a known fixture.
  def seed_catalog_model(api_provider:, model_id:)
    provider = CATALOG[[ api_provider.to_s, model_id.to_s ]]
    return nil if provider.blank?

    seed_model(model_id: model_id, provider: provider)
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
end
