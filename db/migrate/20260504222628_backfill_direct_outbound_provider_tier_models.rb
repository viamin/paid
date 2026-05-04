# frozen_string_literal: true

# Backfills tier_model_ids for existing direct-outbound providers (KiloCode,
# OpenCode) that already have a configured model in their config JSONB but
# were saved before the sync_direct_outbound_tier_models callback existed.
# Re-saving each matching provider triggers the before_save callback which
# creates/finds the LlmModel record and populates tier_model_ids.
class BackfillDirectOutboundProviderTierModels < ActiveRecord::Migration[8.1]
  def up
    Provider.where(auth_type: "api_key", provider_key: %w[kilocode opencode]).find_each do |provider|
      next unless provider.requires_direct_outbound?
      next if provider.tier_model_ids.present?

      provider.save!
    rescue => e # rubocop:disable Style/RescueStandardError
      Rails.logger.warn(
        message: "backfill_direct_outbound_tier_models.skip",
        provider_id: provider.id,
        error: e.message
      )
    end
  end

  def down
    # No-op: removing tier_model_ids could break model selection for active
    # providers, so we intentionally leave them populated on rollback.
  end
end
