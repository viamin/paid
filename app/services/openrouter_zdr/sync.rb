# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Data.define(:models_synced, :endpoints_synced, :status, :error)
    CATALOG_SOURCE = "openrouter_zdr_sync"

    def self.call
      new.call
    end

    # @spec OPENROUTER-ZDR-001
    # @spec OPENROUTER-ZDR-002
    # @spec OPENROUTER-ZDR-003
    # @spec OPENROUTER-ZDR-004
    # @spec OPENROUTER-ZDR-005
    # @spec OPENROUTER-ZDR-006
    def call
      payloads = OpenrouterZdr::Client.call.uniq { |payload| [ payload.fetch("model_id"), payload.fetch("name") ] }
      timestamp = Time.current
      model_ids = payloads.map { |payload| payload.fetch("model_id") }.uniq

      LlmModel.transaction do
        replace_endpoints!(payloads, timestamp)
        deactivate_missing_models!(model_ids)
        mark_available!(model_ids, timestamp)
      end

      result = Result.new(models_synced: model_ids.size, endpoints_synced: payloads.size, status: "available", error: nil)
      log_summary(result)
      result
    rescue OpenrouterZdr::Client::Error => e
      mark_unavailable!(e)
      result = Result.new(models_synced: 0, endpoints_synced: 0, status: "unavailable", error: e.message)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: e.class.name)
      result
    end

    private

    def replace_endpoints!(payloads, timestamp)
      OpenrouterZdrEndpoint.delete_all
      payloads.each do |payload|
        OpenrouterZdrEndpoint.create!(
          model_id: payload.fetch("model_id"),
          endpoint_name: payload.fetch("name"),
          provider_name: payload["provider_name"],
          metadata: payload,
          last_seen_at: timestamp
        )
        upsert_model(payload)
      end
    end

    def upsert_model(payload)
      model = LlmModel.find_or_initialize_by(model_id: payload.fetch("model_id"))
      return refresh_synced_model!(model, payload) if model.persisted? && model.catalog_source == CATALOG_SOURCE

      model.assign_attributes(
        display_name: payload.fetch("model_name", payload.fetch("model_id")),
        provider: "openrouter",
        category: "coding",
        pricing_tier: "paid",
        catalog_source: CATALOG_SOURCE,
        context_window: payload["context_length"],
        max_output_tokens: payload["max_completion_tokens"],
        metadata: payload,
        active: true
      )
      model.save!
      model
    end

    def refresh_synced_model!(model, payload)
      model.update!(display_name: payload.fetch("model_name", payload.fetch("model_id")),
        metadata: payload, context_window: payload["context_length"],
        max_output_tokens: payload["max_completion_tokens"], active: true)
      model
    end

    def deactivate_missing_models!(model_ids)
      LlmModel.where(catalog_source: CATALOG_SOURCE).where.not(model_id: model_ids)
        .update_all(active: false, updated_at: Time.current)
    end

    def mark_available!(model_ids, timestamp)
      sync = OpenrouterZdrSync.current
      sync.update!(status: "available", last_attempted_at: timestamp, last_successful_at: timestamp,
        models_count: model_ids.size, error_message: nil)
    end

    def mark_unavailable!(error)
      sync = OpenrouterZdrSync.current
      sync.update!(status: "unavailable", last_attempted_at: Time.current, error_message: error.message)
    end

    def log_summary(result)
      Rails.logger.info(message: "openrouter_zdr.sync_completed", models_synced: result.models_synced,
        endpoints_synced: result.endpoints_synced)
    end
  end
end
