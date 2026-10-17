# frozen_string_literal: true

# Low-tier catalog rows required by chat fallback fixtures. Fallback selection
# resolves the curated Low tier (CHAT-API-026) before offering a non-free
# runner, so specs that expect a fallback to be offered or switched to must
# give the fixture runner a compatible Low-tier catalog model. Centralized so
# the seeded rows cannot drift between the fallback specs.
module ChatFallbackCatalog
  LOW_TIER_ROWS = [
    { model_id: "moonshotai/kimi-k2-flash", display_name: "Kimi K2 Flash",
      provider: "openrouter", category: "coding", capability_score: 7.5 },
    { model_id: "claude-haiku-4-5", display_name: "Claude Haiku 4.5",
      provider: "anthropic", category: "general", capability_score: 7.0 }
  ].freeze

  module_function

  def seed_low_tier_models
    LOW_TIER_ROWS.each { |row| seed_low_tier_model(model_id: row[:model_id]) }
  end

  def seed_low_tier_model(model_id:)
    row = LOW_TIER_ROWS.find { |candidate| candidate[:model_id] == model_id }
    raise ArgumentError, "no low-tier fixture row for #{model_id.inspect}" unless row

    LlmModel.find_or_create_by!(model_id: row[:model_id]) do |model|
      model.assign_attributes(
        display_name: row[:display_name],
        provider: row[:provider],
        category: row[:category],
        tier: "low",
        capability_score: row[:capability_score],
        supports_tools: true,
        active: true
      )
    end
  end
end
