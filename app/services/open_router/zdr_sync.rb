# frozen_string_literal: true

module OpenRouter
  class ZdrSync
    Result = Data.define(:models_synced, :withdrawn_models, :refreshed_at)

    class InvalidEndpoint < ZdrClient::ParseError; end

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-010
    # @spec FREE-MODEL-SYNC-011
    # @spec FREE-MODEL-SYNC-012
    def call
      refresh!(endpoint_groups)
    rescue ZdrClient::Error => e
      mark_unavailable!(e)
      raise
    end

    private

    def endpoint_groups
      Array(ZdrClient.call).each_with_object({}) do |endpoint, groups|
        model_id = endpoint.is_a?(Hash) && endpoint["model_id"].presence
        raise InvalidEndpoint, "OpenRouter ZDR endpoint did not include a model_id" unless model_id

        groups[model_id] ||= []
        groups[model_id] << endpoint
      end
    end

    def refresh!(groups)
      refreshed_at = Time.current
      withdrawn_models = 0

      OpenRouterZdrCatalog.transaction do
        catalog = OpenRouterZdrCatalog.current.lock!
        withdrawn_models = withdraw_missing_entries!(catalog, groups.keys)
        groups.each { |model_id, endpoints| sync_entry!(catalog, model_id, endpoints) }
        catalog.update!(available: true, last_successful_at: refreshed_at, last_attempted_at: refreshed_at, last_error: nil)
      end

      result = Result.new(models_synced: groups.size, withdrawn_models: withdrawn_models, refreshed_at: refreshed_at)
      log_success(result)
      result
    end

    def withdraw_missing_entries!(catalog, model_ids)
      entries = catalog.entries.includes(:llm_model).joins(:llm_model).where.not(llm_models: { model_id: model_ids })
      entries.each { |entry| deactivate_withdrawn_model!(entry.llm_model) }
      entries.delete_all
    end

    def deactivate_withdrawn_model!(model)
      return unless model.catalog_source == "openrouter_zdr_sync"
      return if model.operator_managed_active?

      model.update!(active: false)
    end

    def sync_entry!(catalog, model_id, endpoints)
      model = find_or_materialize_model(model_id, endpoints)
      entry = catalog.entries.find_or_initialize_by(llm_model: model)
      entry.update!(endpoint_count: endpoints.size, metadata: { "endpoints" => endpoints })
    end

    def find_or_materialize_model(model_id, endpoints)
      model = LlmModel.find_or_initialize_by(model_id: model_id)
      return model unless model.new_record? || model.catalog_source == "openrouter_zdr_sync"

      model.assign_attributes(model_attributes(model, endpoints))
      model.save!
      model
    end

    def model_attributes(model, endpoints)
      endpoint = endpoints.max_by { |candidate| [ candidate["context_length"].to_i, candidate["max_completion_tokens"].to_i ] }
      classification = FreeModels::Classify.call(
        context_window: endpoint["context_length"],
        max_output_tokens: endpoint["max_completion_tokens"],
        supports_tools: Array(endpoint["supported_parameters"]).map(&:to_s).include?("tools"),
        supports_reasoning: Array(endpoint["supported_parameters"]).map(&:to_s).include?("reasoning"),
        multimodal: false
      )

      {
        display_name: endpoint["model_name"].presence || model.model_id,
        provider: model.model_id.split("/", 2).first,
        category: "coding",
        pricing_tier: free_endpoint?(endpoint) ? "free" : "paid",
        catalog_source: "openrouter_zdr_sync",
        data_training_risk: "possible",
        context_window: endpoint["context_length"],
        max_output_tokens: endpoint["max_completion_tokens"],
        supports_tools: Array(endpoint["supported_parameters"]).map(&:to_s).include?("tools"),
        capability_score: classification.score,
        tier: classification.tier,
        input_cost_per_million: per_million_cost(endpoint.dig("pricing", "prompt")),
        output_cost_per_million: per_million_cost(endpoint.dig("pricing", "completion")),
        metadata: { "openrouter_zdr_endpoints" => endpoints },
        active: model.operator_managed_active? ? model.active : true
      }
    end

    def free_endpoint?(endpoint)
      pricing = endpoint["pricing"]
      pricing.is_a?(Hash) && pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0"
    end

    def per_million_cost(value)
      return if value.blank?

      BigDecimal(value.to_s) * 1_000_000
    end

    def mark_unavailable!(error)
      catalog = OpenRouterZdrCatalog.current
      catalog.update!(available: false, last_attempted_at: Time.current, last_error: error.message)
      Rails.logger.warn(message: "openrouter.zdr_sync_unavailable", error_class: error.class.name, error_message: error.message)
    end

    def log_success(result)
      Rails.logger.info(
        message: "openrouter.zdr_sync_completed",
        models_synced: result.models_synced,
        withdrawn_models: result.withdrawn_models,
        refreshed_at: result.refreshed_at
      )
    end
  end
end
