# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Data.define(:models_synced, :removed_models, :available)

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-010
    # @spec FREE-MODEL-SYNC-011
    # @spec FREE-MODEL-SYNC-012
    def call
      endpoints = Client.call
      refresh!(endpoints)
    rescue Client::Error => e
      mark_unavailable!(e)
      Result.new(models_synced: 0, removed_models: 0, available: false)
    end

    private

    def refresh!(endpoints)
      grouped_endpoints = endpoints.group_by { |endpoint| endpoint.fetch("model_id") }
      known_model_ids = LlmModel.where(model_id: grouped_endpoints.keys).pluck(:model_id).to_set
      removed_models = 0
      OpenrouterZdrModel.transaction do
        grouped_endpoints.each { |model_id, payloads| upsert_eligibility!(model_id, payloads, known_model_ids) }
        removed_models = OpenrouterZdrModel.where.not(model_id: grouped_endpoints.keys).delete_all
        mark_available!
      end
      Result.new(models_synced: grouped_endpoints.size, removed_models: removed_models, available: true)
    end

    def upsert_eligibility!(model_id, payloads, known_model_ids)
      OpenrouterZdrModel.upsert({ model_id: model_id, endpoint_count: payloads.size,
        endpoint_payloads: payloads, last_seen_at: Time.current, created_at: Time.current, updated_at: Time.current }, unique_by: :index_openrouter_zdr_models_on_model_id)
      upsert_missing_model!(model_id, payloads.first) unless known_model_ids.include?(model_id)
    end

    def upsert_missing_model!(model_id, endpoint)
      return if LlmModel.exists?(model_id: model_id)

      LlmModel.create!(model_id: model_id, display_name: endpoint["model_name"].presence || model_id,
        provider: model_id.split("/", 2).first, category: "coding", pricing_tier: pricing_tier(endpoint),
        catalog_source: "openrouter_zdr_sync", context_window: endpoint["context_length"],
        max_output_tokens: endpoint["max_completion_tokens"], supports_tools: Array(endpoint["supported_parameters"]).include?("tools"),
        metadata: { "openrouter_zdr_endpoint" => endpoint })
    end

    def pricing_tier(endpoint)
      pricing = endpoint["pricing"] || {}
      pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0" ? "free" : "paid"
    end

    def mark_available!
      OpenrouterZdrCatalog.current.update!(last_attempted_at: Time.current, last_successful_at: Time.current,
        unavailable_at: nil, unavailability_reason: nil)
    end

    def mark_unavailable!(error)
      OpenrouterZdrCatalog.current.update!(last_attempted_at: Time.current, unavailable_at: Time.current,
        unavailability_reason: error.class.name)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: error.class.name)
    end
  end
end
