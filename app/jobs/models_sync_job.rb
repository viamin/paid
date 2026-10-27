# frozen_string_literal: true

class ModelsSyncJob < ApplicationJob
  queue_as :default

  # @spec MODEL-AVAILABILITY-004 MODEL-AVAILABILITY-008
  def perform
    synced, checked = Models::CatalogSnapshot.refresh do
      [ Models::SeedKnownModels.call, Models::ReconcileAvailability.refresh_known_contexts! ]
    end

    Rails.logger.info(
      message: "model_registry.availability_refreshed",
      models_synced: synced,
      models_checked: checked.values.sum,
      contexts: checked
    )
  end
end
