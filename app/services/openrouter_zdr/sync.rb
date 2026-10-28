# frozen_string_literal: true

module OpenrouterZdr
  class Sync
    Result = Data.define(:status, :models_synced, :removed_models) do
      def success? = status == :success
      def unavailable? = status == :unavailable
    end

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-009, FREE-MODEL-SYNC-010, FREE-MODEL-SYNC-011, FREE-MODEL-SYNC-012
    def call
      refresh = OpenrouterZdrCatalogRefresh.current
      refresh.update!(last_attempted_at: Time.current, last_error: nil)
      endpoints_by_model_id = endpoint_records_by_model_id(Client.call)
      sync_eligible_models!(endpoints_by_model_id)
      refresh.update!(last_successful_at: Time.current, last_error: nil)
      Result.new(status: :success, models_synced: endpoints_by_model_id.size, removed_models: remove_withdrawn_eligibility!(endpoints_by_model_id.keys))
    rescue Client::Error => e
      record_unavailability(e)
    end

    private

    def endpoint_records_by_model_id(records)
      records.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |record, grouped|
        unless record.is_a?(Hash) && record["model_id"].present?
          raise Client::ParseError, "OpenRouter ZDR endpoint record did not include a model_id"
        end

        grouped[record.fetch("model_id")] << record
      end
    end

    def sync_eligible_models!(endpoints_by_model_id)
      LlmModel.transaction do
        endpoints_by_model_id.each do |model_id, endpoints|
          model = LlmModel.find_or_initialize_by(model_id: model_id)
          model.assign_attributes(new_model_attributes(model_id, endpoints.first)) if model.new_record?
          model.update!(openrouter_zdr_eligible: true, openrouter_zdr_endpoint_metadata: endpoints)
        end
      end
    end

    def new_model_attributes(model_id, endpoint)
      supported_parameters = Array(endpoint["supported_parameters"]).map(&:to_s)
      {
        display_name: endpoint["model_name"].presence || model_id,
        provider: model_id.split("/", 2).first,
        category: "coding",
        pricing_tier: free_endpoint?(endpoint) ? "free" : "paid",
        catalog_source: "openrouter_sync",
        context_window: endpoint["context_length"],
        max_output_tokens: endpoint["max_completion_tokens"],
        supports_tools: supported_parameters.include?("tools"),
        metadata: { "openrouter_zdr_catalog_only" => true }
      }
    end

    def free_endpoint?(endpoint)
      pricing = endpoint["pricing"]
      pricing.is_a?(Hash) && pricing["prompt"].to_s == "0" && pricing["completion"].to_s == "0"
    end

    def remove_withdrawn_eligibility!(model_ids)
      LlmModel.where(openrouter_zdr_eligible: true).where.not(model_id: model_ids)
        .update_all(openrouter_zdr_eligible: false, openrouter_zdr_endpoint_metadata: {}, updated_at: Time.current)
    end

    def record_unavailability(error)
      refresh = OpenrouterZdrCatalogRefresh.current
      refresh.update!(last_attempted_at: Time.current, last_error: error.message)
      Rails.logger.warn(
        message: "openrouter_zdr.sync_unavailable",
        error_class: error.class.name,
        error_message: error.message
      )
      Result.new(status: :unavailable, models_synced: 0, removed_models: 0)
    end
  end
end
