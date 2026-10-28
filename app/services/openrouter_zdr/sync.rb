# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Struct.new(:models_synced, :removed_models, :available, keyword_init: true)

    def self.call
      new.call
    end

    # @spec OPENROUTER-ZDR-CATALOG-001
    # @spec OPENROUTER-ZDR-CATALOG-002
    # @spec OPENROUTER-ZDR-CATALOG-003
    # @spec OPENROUTER-ZDR-CATALOG-004
    def call
      endpoints = Array(Client.call)
      validate_endpoints!(endpoints)
      sync_endpoints!(endpoints)
    rescue Client::Error => e
      mark_unavailable!(e)
      Result.new(models_synced: 0, removed_models: 0, available: false)
    end

    private

    def validate_endpoints!(endpoints)
      return if endpoints.all? { |endpoint| endpoint.is_a?(Hash) && endpoint["model_id"].present? }

      raise Client::ParseError, "OpenRouter ZDR response included an endpoint without a model_id"
    end

    def sync_endpoints!(endpoints)
      models = endpoints.group_by { |endpoint| endpoint.fetch("model_id") }
      now = Time.current
      removed_models = 0

      OpenrouterZdrEligibility.transaction do
        models.each { |model_id, records| upsert_eligibility!(model_id, records, now) }
        removed_models = OpenrouterZdrEligibility.active.where.not(model_id: models.keys).update_all(active: false, updated_at: now)
        mark_verified!(now)
      end

      result = Result.new(models_synced: models.size, removed_models:, available: true)
      Rails.logger.info(message: "openrouter_zdr.sync_completed", models_synced: result.models_synced,
        removed_models: result.removed_models)
      result
    end

    def upsert_eligibility!(model_id, endpoints, now)
      OpenrouterZdrEligibility.find_or_initialize_by(model_id:).tap do |eligibility|
        eligibility.assign_attributes(endpoint_metadata: endpoints, endpoint_count: endpoints.size, active: true, last_seen_at: now)
        eligibility.save!
      end
      upsert_model_if_missing!(model_id, endpoints.first)
    end

    def upsert_model_if_missing!(model_id, endpoint)
      return if LlmModel.exists?(model_id:)

      LlmModel.create!(model_id:, display_name: endpoint["model_name"].presence || model_id,
        provider: model_id.split("/", 2).first, category: "coding", tier: "mid", active: true,
        catalog_source: "openrouter_zdr_sync", pricing_tier: pricing_tier(endpoint),
        context_window: endpoint["context_length"], max_output_tokens: endpoint["max_completion_tokens"],
        supports_tools: Array(endpoint["supported_parameters"]).map(&:to_s).include?("tools"),
        metadata: { "openrouter_zdr_endpoints" => [ endpoint ] })
    end

    def pricing_tier(endpoint)
      pricing = endpoint["pricing"]
      return "paid" unless pricing.is_a?(Hash)

      pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0" ? "free" : "paid"
    end

    def mark_verified!(now)
      OpenrouterZdrCatalogStatus.current.update!(status: "verified", last_attempted_at: now,
        last_successful_at: now, last_error: nil)
    end

    def mark_unavailable!(error)
      OpenrouterZdrCatalogStatus.current.update!(status: "unavailable", last_attempted_at: Time.current,
        last_error: error.class.name)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: error.class.name)
    end
  end
end
