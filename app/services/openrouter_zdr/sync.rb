# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Struct.new(:models_synced, :withdrawn_models, :unavailable, keyword_init: true) do
      def unavailable? = unavailable
    end

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-010
    # @spec FREE-MODEL-SYNC-011
    # @spec FREE-MODEL-SYNC-012
    def call
      state = OpenrouterZdrCatalogState.current
      state.update!(last_attempted_at: Time.current)
      sync!(Array(Client.call), state)
    rescue Client::Error => e
      mark_unavailable(state, e)
    end

    private

    def sync!(endpoints, state)
      raise Client::ParseError, "OpenRouter ZDR endpoint response included an invalid endpoint" unless endpoints.all? { |endpoint| valid_endpoint?(endpoint) }

      grouped = endpoints.group_by { |endpoint| endpoint.fetch("model_id") }
      withdrawn_models = 0
      LlmModel.transaction do
        grouped.each { |model_id, model_endpoints| upsert_model(model_id, model_endpoints) }
        withdrawn_models = withdraw_missing_models!(grouped.keys)
        state.update!(last_successful_at: Time.current, unavailable_at: nil, last_error: nil)
      end
      result = Result.new(models_synced: grouped.size, withdrawn_models:, unavailable: false)
      log_completed(result)
      result
    end

    def valid_endpoint?(endpoint)
      endpoint.is_a?(Hash) && endpoint["model_id"].is_a?(String) && endpoint["model_id"].include?("/")
    end

    def upsert_model(model_id, endpoints)
      model = LlmModel.find_or_initialize_by(model_id: model_id)
      model.assign_attributes(new_model_attributes(model_id, endpoints.first)) if model.new_record?
      model.metadata = model.metadata.merge("openrouter_zdr" => { "endpoints" => endpoints, "checked_at" => Time.current.iso8601 })
      model.assign_attributes(openrouter_zdr_eligible: true, openrouter_zdr_checked_at: Time.current)
      model.active = true if model.catalog_source == "openrouter_zdr_sync"
      model.save! if model.changed? || model.new_record?
    end

    def new_model_attributes(model_id, endpoint)
      pricing = endpoint.fetch("pricing", {})
      supported_parameters = Array(endpoint["supported_parameters"]).map(&:to_s)
      {
        display_name: endpoint["model_name"].presence || model_id,
        provider: model_id.split("/", 2).first,
        category: "coding",
        pricing_tier: free?(pricing) ? "free" : "paid",
        catalog_source: "openrouter_zdr_sync",
        data_training_risk: "unknown",
        context_window: endpoint["context_length"],
        max_output_tokens: endpoint["max_completion_tokens"],
        supports_tools: supported_parameters.include?("tools"),
        capability_score: nil,
        tier: nil,
        active: true
      }
    end

    def free?(pricing)
      pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0"
    end

    def withdraw_missing_models!(model_ids)
      withdrawn_models = LlmModel.where(openrouter_zdr_eligible: true).where.not(model_id: model_ids)
      withdrawn_count = withdrawn_models.count
      withdrawn_models.find_each do |model|
        attributes = { openrouter_zdr_eligible: false, openrouter_zdr_checked_at: Time.current }
        attributes[:active] = false if model.catalog_source == "openrouter_zdr_sync"
        model.update!(attributes)
      end
      withdrawn_count
    end

    def mark_unavailable(state, error)
      state.update!(unavailable_at: Time.current, last_error: error.message)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: error.class.name)
      Result.new(models_synced: 0, withdrawn_models: 0, unavailable: true)
    end

    def log_completed(result)
      Rails.logger.info(message: "openrouter_zdr.sync_completed", models_synced: result.models_synced,
        withdrawn_models: result.withdrawn_models)
    end
  end
end
