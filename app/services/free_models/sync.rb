# frozen_string_literal: true

module FreeModels
  class Sync
    Result = Struct.new(:models_synced, :new_models, :removed_models, keyword_init: true)

    FREE_PRICE = "0"
    FREE_SUFFIX = ":free"
    IMAGE_MODALITY = "image"
    MULTIMODAL_MODALITIES = %w[image video].freeze

    def self.call
      new.call
    end

    # @spec FREE-MODEL-SYNC-001
    # @spec FREE-MODEL-SYNC-002
    # @spec FREE-MODEL-SYNC-003
    # @spec FREE-MODEL-SYNC-004
    # @spec FREE-MODEL-SYNC-005
    # @spec FREE-MODEL-SYNC-006
    # @spec FREE-MODEL-SYNC-007
    def call
      payloads = Array(FreeModels::Client.call)
      free_payloads = payloads.select { |payload| free_model_payload?(payload) }
      synced_ids = []
      new_models = 0
      removed_models = 0

      LlmModel.transaction do
        free_payloads.each do |payload|
          model, created = upsert_model(payload)
          synced_ids << model.model_id
          new_models += 1 if created
        end

        removed_models = deactivate_missing_models!(synced_ids)
      end

      result = Result.new(models_synced: synced_ids.size, new_models: new_models, removed_models: removed_models)
      log_summary(result)
      result
    end

    private

    def free_model_payload?(payload)
      pricing = payload["pricing"]
      pricing.is_a?(Hash) &&
        pricing["prompt"].to_s == FREE_PRICE &&
        pricing["completion"].to_s == FREE_PRICE
    end

    def upsert_model(payload)
      attributes = model_attributes(payload)
      model = LlmModel.find_or_initialize_by(model_id: payload.fetch("id"))
      created = model.new_record?
      model.assign_attributes(attributes)
      model.save!
      [ model, created ]
    end

    def model_attributes(payload)
      supported_parameters = Array(payload["supported_parameters"]).map(&:to_s)
      input_modalities = Array(payload.dig("architecture", "input_modalities")).map(&:to_s)
      context_window = payload["context_length"]
      max_output_tokens = payload.dig("top_provider", "max_completion_tokens")
      supports_tools = supported_parameters.include?("tools")
      supports_reasoning = supported_parameters.include?("reasoning")
      multimodal = (input_modalities & MULTIMODAL_MODALITIES).any?
      classification = FreeModels::Classify.call(
        context_window: context_window,
        max_output_tokens: max_output_tokens,
        supports_tools: supports_tools,
        supports_reasoning: supports_reasoning,
        multimodal: multimodal
      )
      below_quality_bar = FreeModels::QualityFilter.call(
        context_window: context_window,
        supports_tools: supports_tools
      )

      {
        display_name: payload["name"].presence || payload.fetch("id"),
        provider: payload.fetch("id").split("/", 2).first,
        category: "coding",
        pricing_tier: "free",
        catalog_source: "openrouter_sync",
        data_training_risk: "possible",
        context_window: context_window,
        max_output_tokens: max_output_tokens,
        supports_tools: supports_tools,
        supports_vision: input_modalities.include?(IMAGE_MODALITY),
        capability_score: classification.score,
        tier: classification.tier,
        metadata: payload.merge("below_quality_bar" => below_quality_bar),
        free_variant_of: free_variant_for(payload.fetch("id")),
        expires_at: parsed_expiration(payload["expiration_date"]),
        active: true
      }
    end

    def free_variant_for(model_id)
      base_id = model_id.delete_suffix(FREE_SUFFIX)
      return nil if base_id == model_id

      LlmModel.find_by(model_id: base_id)
    end

    def parsed_expiration(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-004
    def deactivate_missing_models!(synced_ids)
      LlmModel.openrouter_synced_free.where.not(model_id: synced_ids).update_all(active: false, updated_at: Time.current)
    end

    def log_summary(result)
      Rails.logger.info(
        message: "free_models.sync_completed",
        models_synced: result.models_synced,
        new_models: result.new_models,
        removed_models: result.removed_models
      )
    end
  end
end
