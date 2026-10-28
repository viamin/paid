# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Data.define(:models_synced, :new_models, :withdrawn_models)
    FREE_PRICE = "0"

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009
    # @spec FREE-MODEL-SYNC-010
    # @spec FREE-MODEL-SYNC-011
    # @spec FREE-MODEL-SYNC-012
    # @spec FREE-MODEL-SYNC-013
    def call
      endpoint_groups = endpoint_groups_for(OpenrouterZdr::Client.call)
      refreshed_at = Time.current
      status = OpenrouterZdrCatalogStatus.current

      result = LlmModel.transaction do
        synced, created = sync_models!(endpoint_groups, refreshed_at)
        withdrawn = withdraw_missing_eligibility!(endpoint_groups.keys, refreshed_at)
        status.update!(status: "available", last_attempt_at: refreshed_at, last_success_at: refreshed_at, last_error: nil)
        Result.new(models_synced: synced, new_models: created, withdrawn_models: withdrawn)
      end

      log_summary(result)
      result
    rescue OpenrouterZdr::Client::Error => e
      record_unavailability!(e)
      raise
    end

    private

    def endpoint_groups_for(payloads)
      Array(payloads).each_with_object({}) do |payload, groups|
        unless payload.is_a?(Hash) && payload["model_id"].present?
          raise OpenrouterZdr::Client::ParseError, "OpenRouter ZDR endpoint was missing model_id"
        end

        (groups[payload.fetch("model_id")] ||= []) << payload
      end
    end

    def sync_models!(endpoint_groups, refreshed_at)
      endpoint_groups.each_with_object([ 0, 0 ]) do |(model_id, endpoints), counts|
        _model, created = upsert_model(model_id, endpoints, refreshed_at)
        counts[0] += 1
        counts[1] += 1 if created
      end
    end

    def upsert_model(model_id, endpoints, refreshed_at)
      model = LlmModel.find_or_initialize_by(model_id:)
      created = model.new_record?
      model.assign_attributes(new_model_attributes(model_id, endpoints)) if created
      model.assign_attributes(zdr_attributes(model, endpoints, refreshed_at))
      model.save!
      [ model, created ]
    end

    def new_model_attributes(model_id, endpoints)
      representative = endpoints.max_by { |endpoint| endpoint["context_length"].to_i }
      supported_parameters = endpoints.flat_map { |endpoint| Array(endpoint["supported_parameters"]) }.map(&:to_s).uniq
      pricing = representative["pricing"]

      {
        display_name: representative["model_name"].presence || model_id,
        provider: model_id.split("/", 2).first,
        category: "coding",
        pricing_tier: free_pricing?(pricing) ? "free" : "paid",
        catalog_source: "openrouter_zdr_sync",
        data_training_risk: "unknown",
        context_window: representative["context_length"],
        max_output_tokens: representative["max_completion_tokens"],
        supports_tools: supported_parameters.include?("tools"),
        metadata: {}
      }
    end

    def zdr_attributes(model, endpoints, refreshed_at)
      {
        zdr_eligible: true,
        zdr_checked_at: refreshed_at,
        metadata: model.metadata.merge(
          "openrouter_zdr_endpoints" => endpoints,
          "openrouter_zdr_endpoint_count" => endpoints.size
        )
      }
    end

    def free_pricing?(pricing)
      pricing.is_a?(Hash) && pricing["prompt"].to_s == FREE_PRICE && pricing["completion"].to_s == FREE_PRICE
    end

    def withdraw_missing_eligibility!(model_ids, refreshed_at)
      LlmModel.openrouter_zdr_eligible.where.not(model_id: model_ids)
        .update_all(zdr_eligible: false, zdr_checked_at: refreshed_at, updated_at: refreshed_at)
    end

    def record_unavailability!(error)
      status = OpenrouterZdrCatalogStatus.current
      status.update!(status: "unavailable", last_attempt_at: Time.current, last_error: error.message)
      Rails.logger.warn(message: "openrouter_zdr.sync_unavailable", error_class: error.class.name, error_message: error.message)
    end

    def log_summary(result)
      Rails.logger.info(
        message: "openrouter_zdr.sync_completed",
        models_synced: result.models_synced,
        new_models: result.new_models,
        withdrawn_models: result.withdrawn_models
      )
    end
  end
end
