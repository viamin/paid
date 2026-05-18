# frozen_string_literal: true

# Backfills tier_model_ids for existing direct-outbound providers (KiloCode,
# OpenCode) that already have a configured model in their config JSONB but
# were saved before the sync_direct_outbound_tier_models callback existed.
# Re-saving each matching provider triggers the before_save callback which
# creates/finds the LlmModel record and populates tier_model_ids.
#
class BackfillDirectOutboundProviderTierModels < ActiveRecord::Migration[8.1]
  class MigrationProvider < ActiveRecord::Base
    self.table_name = "providers"
  end

  class MigrationLlmModel < ActiveRecord::Base
    self.table_name = "llm_models"
  end

  DIRECT_OUTBOUND_API_PROVIDERS = {
    "openrouter" => { service_type: "openrouter" },
    "anthropic" => { service_type: "anthropic" },
    "openai" => { service_type: "openai" },
    "inception" => { service_type: "inception" },
    "deepseek" => { service_type: "deepseek" },
    "mistral" => { service_type: "mistral" },
    "xai" => { service_type: "xai" },
    "zai" => { service_type: "zai" },
    "zai_coding" => { service_type: "zai_coding" }
  }.freeze
  DIRECT_OUTBOUND_MODEL_TIER_HINTS = {
    "glm-5.1" => "high",
    "glm-4.7" => "mid",
    "glm-4.5-air" => "low"
  }.freeze
  OPENCODE_DEFAULT_API_PROVIDER = "openrouter"
  KILOCODE_DEFAULT_API_PROVIDER = "anthropic"
  TIERS = %w[low mid high].freeze

  def up
    failures = []
    MigrationProvider.where(auth_type: "api_key", provider_key: %w[kilocode opencode]).find_each do |provider|
      next unless requires_direct_outbound?(provider)
      next if provider.tier_model_ids.present?

      model_id = direct_outbound_model_id(provider)
      model_provider = direct_outbound_service_type(provider)
      next if model_id.blank? || model_provider.blank?

      ensure_llm_model!(model_id, model_provider)
      provider.update!(
        tier_model_ids: TIERS.index_with { model_id }
      )
    rescue StandardError => e
      failures << { id: provider.id, error: e.message }
      Rails.logger.warn(
        message: "backfill_direct_outbound_tier_models.skip",
        provider_id: provider.id,
        error: e.message
      )
    end

    if failures.any?
      summary = failures.map { |f| "provider ##{f[:id]}: #{f[:error]}" }.join("; ")
      raise "BackfillDirectOutboundProviderTierModels failed for #{failures.size} provider(s): #{summary}"
    end
  end

  def down
    # No-op: removing tier_model_ids could break model selection for active
    # providers, so we intentionally leave them populated on rollback.
  end

  private

  def requires_direct_outbound?(provider)
    direct_outbound_model_id(provider).present? && direct_outbound_service_type(provider).present?
  end

  def direct_outbound_model_id(provider)
    config = provider.config.is_a?(Hash) ? provider.config : {}

    case provider.provider_key
    when "opencode"
      config.fetch("opencode", {}).fetch("model", "").to_s.presence
    when "kilocode"
      config.fetch("kilocode", {}).fetch("model", "").to_s.presence
    end
  end

  def direct_outbound_service_type(provider)
    config = provider.config.is_a?(Hash) ? provider.config : {}

    api_provider = case provider.provider_key
    when "opencode"
      config.fetch("opencode", {}).fetch("api_provider", "").presence || OPENCODE_DEFAULT_API_PROVIDER
    when "kilocode"
      config.fetch("kilocode", {}).fetch("api_provider", "").presence || KILOCODE_DEFAULT_API_PROVIDER
    end

    DIRECT_OUTBOUND_API_PROVIDERS.dig(api_provider, :service_type)
  end

  def ensure_llm_model!(model_id, model_provider)
    model = MigrationLlmModel.find_or_initialize_by(model_id: model_id)
    model.display_name = direct_outbound_display_name(model_id) if model.display_name.blank?
    model.provider = model_provider
    model.category ||= "coding"
    model.tier ||= DIRECT_OUTBOUND_MODEL_TIER_HINTS[model_id] || "mid"
    model.active = true
    model.save!
    model
  rescue ActiveRecord::RecordNotUnique
    MigrationLlmModel.find_by!(model_id: model_id)
  end

  def direct_outbound_display_name(model_id)
    base = model_id.include?("/") ? model_id.split("/").last : model_id
    base.tr("_-", " ").split.map(&:capitalize).join(" ")
  end
end
