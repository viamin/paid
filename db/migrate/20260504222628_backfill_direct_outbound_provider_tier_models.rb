# frozen_string_literal: true

# Backfills tier_model_ids for existing direct-outbound providers (KiloCode,
# OpenCode) that already have a configured model in their config JSONB but
# were saved before the sync_direct_outbound_tier_models callback existed.
# Re-saving each matching provider triggers the before_save callback which
# creates/finds the LlmModel record and populates tier_model_ids.
#
# Uses the live Provider model for the sync callback. This is acceptable
# because: (1) fresh installs have no data to backfill; (2) schema loads
# (db:schema:load) skip migrations entirely; (3) the callback is idempotent.
class BackfillDirectOutboundProviderTierModels < ActiveRecord::Migration[8.1]
  def up
    failures = []
    Provider.where(auth_type: "api_key", provider_key: %w[kilocode opencode]).find_each do |provider|
      next unless provider.requires_direct_outbound?
      next if provider.tier_model_ids.present?

      provider.save!
    rescue => e # rubocop:disable Style/RescueStandardError
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
end
