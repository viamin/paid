# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Data.define(:models_synced, :new_models, :removed_models)

    def self.call(...)
      new(...).call
    end

    # @spec FREE-MODEL-SYNC-009, FREE-MODEL-SYNC-010, FREE-MODEL-SYNC-011
    def call
      endpoints = Client.call
      synchronize!(endpoints)
    rescue Client::Error => e
      record_unavailable!(e)
      raise
    end

    private

    def synchronize!(endpoints)
      endpoints_by_model_id = endpoints.group_by { |endpoint| endpoint.fetch("model_id") }
      now = Time.current
      new_models = 0
      removed_models = 0

      LlmModel.transaction do
        endpoints_by_model_id.each do |model_id, model_endpoints|
          new_models += 1 if upsert_model(model_id, model_endpoints, now)
        end
        removed_models = withdraw_missing_eligibility!(endpoints_by_model_id.keys, now)
        record_success!(now)
      end

      result = Result.new(models_synced: endpoints_by_model_id.size, new_models:, removed_models:)
      log_summary(result)
      result
    end

    def upsert_model(model_id, endpoints, refreshed_at)
      model = LlmModel.find_or_initialize_by(model_id:)
      created = model.new_record?
      model.assign_attributes(attributes_for(model, endpoints, refreshed_at))
      model.save!
      created
    end

    def attributes_for(model, endpoints, refreshed_at)
      endpoint = endpoints.first
      metadata = model.metadata.merge(
        "openrouter_zdr_eligible" => true,
        "openrouter_zdr_endpoints" => endpoints,
        "openrouter_zdr_refreshed_at" => refreshed_at.iso8601
      )
      unless model.new_record?
        return { metadata: } unless model.catalog_source == "openrouter_zdr" && !model.operator_managed_active?

        return { metadata:, active: true }
      end

      pricing = endpoint.fetch("pricing", {})
      {
        display_name: endpoint["model_name"].presence || model.model_id,
        provider: model.model_id.split("/", 2).first,
        category: "coding",
        pricing_tier: pricing_tier(pricing),
        catalog_source: "openrouter_zdr",
        data_training_risk: "unknown",
        context_window: endpoint["context_length"],
        max_output_tokens: endpoint["max_completion_tokens"],
        supports_tools: Array(endpoint["supported_parameters"]).map(&:to_s).include?("tools"),
        capability_score: 0,
        metadata:,
        active: true
      }
    end

    def pricing_tier(pricing)
      return "free" if pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0"

      "paid"
    end

    def withdraw_missing_eligibility!(model_ids, refreshed_at)
      LlmModel.openrouter_zdr_eligible.where.not(model_id: model_ids).find_each.sum do |model|
        model.update!(
          metadata: model.metadata.merge(
            "openrouter_zdr_eligible" => false,
            "openrouter_zdr_refreshed_at" => refreshed_at.iso8601
          ),
          active: model.catalog_source == "openrouter_zdr" ? false : model.active
        )
        1
      end
    end

    def record_success!(now)
      OpenrouterZdrCatalogRefresh.current.update!(
        status: "successful",
        last_attempted_at: now,
        last_successful_at: now,
        unavailable_at: nil,
        error_class: nil,
        error_message: nil
      )
    end

    def record_unavailable!(error)
      now = Time.current
      OpenrouterZdrCatalogRefresh.current.update!(
        status: "unavailable",
        last_attempted_at: now,
        unavailable_at: now,
        error_class: error.class.name,
        error_message: error.message
      )
    end

    def log_summary(result)
      Rails.logger.info(
        message: "openrouter_zdr.sync_completed",
        models_synced: result.models_synced,
        new_models: result.new_models,
        removed_models: result.removed_models
      )
    end
  end
end
