# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Data.define(:models_synced, :withdrawn_models)

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-010
    # @spec FREE-MODEL-SYNC-011
    # @spec FREE-MODEL-SYNC-012
    def call
      endpoint_groups = endpoint_groups_for(Client.call)
      result = persist(endpoint_groups)
      log_success(result)
      result
    rescue Client::Error => e
      OpenrouterZdrRefresh.current.mark_unavailable!(error: e)
      log_failure(e)
      raise
    end

    private

    def endpoint_groups_for(payloads)
      Array(payloads).each_with_object({}) do |payload, groups|
        unless valid_endpoint?(payload)
          raise Client::ParseError, "OpenRouter ZDR endpoint response included an invalid endpoint"
        end

        groups[payload.fetch("model_id")] ||= []
        groups[payload.fetch("model_id")] << payload
      end
    end

    def valid_endpoint?(payload)
      payload.is_a?(Hash) && payload["model_id"].to_s.present? && payload["model_name"].to_s.present?
    end

    def persist(endpoint_groups)
      LlmModel.transaction do
        endpoint_groups.each_value { |endpoints| upsert_model(endpoints) }
        withdrawn = withdraw_missing_models!(endpoint_groups.keys)
        OpenrouterZdrRefresh.current.mark_available!
        Result.new(models_synced: endpoint_groups.size, withdrawn_models: withdrawn)
      end
    end

    def upsert_model(endpoints)
      primary = endpoints.max_by { |endpoint| [ endpoint["context_length"].to_i, endpoint["max_completion_tokens"].to_i ] }
      model = LlmModel.find_or_initialize_by(model_id: primary.fetch("model_id"))
      model.assign_attributes(model_attributes(model, primary, endpoints))
      model.save!
    end

    def model_attributes(model, primary, endpoints)
      attributes = {
        openrouter_zdr_eligible: true,
        metadata: model.metadata.merge("openrouter_zdr_endpoints" => endpoints)
      }
      return attributes unless model.new_record? || model.catalog_source == "openrouter_zdr_sync"

      classification = FreeModels::Classify.call(
        context_window: primary["context_length"],
        max_output_tokens: primary["max_completion_tokens"],
        supports_tools: Array(primary["supported_parameters"]).map(&:to_s).include?("tools"),
        supports_reasoning: Array(primary["supported_parameters"]).map(&:to_s).include?("reasoning"),
        multimodal: false
      )
      attributes.merge(
        provider: "openrouter",
        family: "openrouter",
        category: "coding",
        pricing_tier: free_pricing?(primary) ? "free" : "paid",
        catalog_source: "openrouter_zdr_sync",
        data_training_risk: "unknown",
        active: true,
        display_name: primary.fetch("model_name"),
        context_window: primary["context_length"],
        max_output_tokens: primary["max_completion_tokens"],
        supports_tools: Array(primary["supported_parameters"]).map(&:to_s).include?("tools"),
        capability_score: classification.score,
        tier: classification.tier,
        input_cost_per_million: cost_per_million(primary.dig("pricing", "prompt")),
        output_cost_per_million: cost_per_million(primary.dig("pricing", "completion"))
      )
    end

    def free_pricing?(endpoint)
      pricing = endpoint["pricing"]
      pricing.is_a?(Hash) && pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0"
    end

    def cost_per_million(value)
      return if value.blank?

      BigDecimal(value.to_s) * 1_000_000
    end

    def withdraw_missing_models!(model_ids)
      withdrawn = LlmModel.openrouter_zdr_eligible.where.not(model_id: model_ids)
      count = withdrawn.update_all(openrouter_zdr_eligible: false, updated_at: Time.current)
      LlmModel.where(catalog_source: "openrouter_zdr_sync", openrouter_zdr_eligible: false)
        .update_all(active: false, updated_at: Time.current)
      count
    end

    def log_success(result)
      Rails.logger.info(message: "openrouter_zdr.sync_completed", models_synced: result.models_synced,
        withdrawn_models: result.withdrawn_models)
    end

    def log_failure(error)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: error.class.name,
        error_message: error.message)
    end
  end
end
