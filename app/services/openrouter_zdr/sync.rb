# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    class MappingError < StandardError; end

    Result = Data.define(:models_synced, :removed_models)

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-010
    # @spec FREE-MODEL-SYNC-011
    # @spec FREE-MODEL-SYNC-012
    def call
      snapshot = Client.call
      candidates = candidates_for(snapshot)
      refresh!(candidates)
    rescue Client::Error, MappingError => e
      mark_unavailable!(e)
      raise
    end

    private

    def candidates_for(snapshot)
      models_by_id = snapshot.models.index_by { |model| model.fetch("id") }
      snapshot.endpoints.group_by { |endpoint| endpoint.fetch("model_id") }.transform_values do |endpoints|
        model = models_by_id[endpoints.first.fetch("model_id")]
        raise MappingError, "OpenRouter ZDR endpoint model is absent from the model catalog" unless model

        { model: model, endpoints: endpoints }
      end
    rescue KeyError => e
      raise MappingError, "OpenRouter ZDR response is malformed: #{e.message}"
    end

    def refresh!(candidates)
      now = Time.current
      result = nil
      OpenrouterZdrModel.transaction do
        candidates.each do |model_id, candidate|
          refresh_candidate!(model_id, candidate, now)
        end
        removed = OpenrouterZdrModel.active.where.not(model_id: candidates.keys).update_all(active: false, updated_at: now)
        state.update!(last_successful_refresh_at: now, last_attempted_refresh_at: now, unavailable_at: nil, last_error_class: nil)
        result = Result.new(models_synced: candidates.size, removed_models: removed)
      end
      log_completed(result)
      result
    end

    def refresh_candidate!(model_id, candidate, now)
      OpenrouterZdrModel.find_or_initialize_by(model_id: model_id).update!(
        active: true,
        last_verified_at: now,
        metadata: { "model" => candidate[:model], "endpoints" => candidate[:endpoints] }
      )
      refresh_llm_model!(model_id, candidate[:model])
    end

    def refresh_llm_model!(model_id, payload)
      model = LlmModel.find_or_initialize_by(model_id: model_id)
      return unless model.new_record? || model.catalog_source == "openrouter_zdr_sync"

      model.assign_attributes(llm_model_attributes(payload))
      model.save!
    end

    def llm_model_attributes(payload)
      supported_parameters = Array(payload["supported_parameters"]).map(&:to_s)
      pricing = payload.fetch("pricing", {})
      context_window = payload["context_length"]
      max_output_tokens = payload.dig("top_provider", "max_completion_tokens")
      supports_tools = supported_parameters.include?("tools")
      classification = FreeModels::Classify.call(context_window:, max_output_tokens:, supports_tools:, supports_reasoning: supported_parameters.include?("reasoning"), multimodal: false)

      {
        display_name: payload["name"].presence || payload.fetch("id"), provider: "openrouter", category: "coding",
        pricing_tier: free_pricing?(pricing) ? "free" : "paid", catalog_source: "openrouter_zdr_sync",
        data_training_risk: "possible", context_window:, max_output_tokens:, supports_tools:, capability_score: classification.score,
        tier: classification.tier, input_cost_per_million: per_million(pricing["prompt"]),
        output_cost_per_million: per_million(pricing["completion"]), metadata: payload, active: true
      }
    end

    def free_pricing?(pricing)
      pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0"
    end

    def per_million(value)
      BigDecimal(value.to_s.presence || "0") * 1_000_000
    end

    def state
      @state ||= OpenrouterZdrCatalogState.instance
    end

    def mark_unavailable!(error)
      state.update!(last_attempted_refresh_at: Time.current, unavailable_at: Time.current, last_error_class: error.class.name)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: error.class.name)
    end

    def log_completed(result)
      Rails.logger.info(message: "openrouter_zdr.sync_completed", models_synced: result.models_synced, removed_models: result.removed_models)
    end
  end
end
