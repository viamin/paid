# frozen_string_literal: true

module Runners
  # Shared data-classification → OpenRouter provider routing logic.
  #
  # Both the free-model and Pareto OpenRouter runners translate a project's
  # data classification into the same OpenRouter provider routing options
  # (data_collection / zdr). Centralizing this keeps the security-relevant
  # mapping in a single place so the two runners can never silently drift.
  module OpenRouterDataRouting
    DEFAULT_DATA_CLASSIFICATION = "internal"

    def build_provider_routing(project, zero_data_retention: false)
      routing = case data_classification_for(project)
      when "open", "internal"
        { data_collection: "allow" }
      when "confidential"
        { data_collection: "deny" }
      when "restricted"
        { data_collection: "deny", zdr: true }
      else
        { data_collection: "allow" }
      end

      # OpenRouter treats ZDR as an inference-routing requirement. A request
      # asking for it must also deny provider data collection; allowing that
      # flag to remain "allow" would let a runner declaration weaken privacy.
      routing[:data_collection] = "deny" if zero_data_retention
      routing[:zdr] = true if zero_data_retention
      routing
    end

    def data_classification_for(project)
      return DEFAULT_DATA_CLASSIFICATION unless project&.respond_to?(:data_classification)

      project.data_classification.presence || DEFAULT_DATA_CLASSIFICATION
    end
  end
end
