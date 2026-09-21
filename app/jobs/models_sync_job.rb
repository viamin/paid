# frozen_string_literal: true

class ModelsSyncJob < ApplicationJob
  queue_as :default

  # @spec MODEL-AVAILABILITY-004
  def perform
    synced = Models::SeedKnownModels.call
    checked = Models::ReconcileAvailability.refresh_known_contexts!

    Rails.logger.info(
      message: "model_registry.availability_refreshed",
      models_synced: synced,
      models_checked: checked.values.sum,
      contexts: checked
    )
  end
end
