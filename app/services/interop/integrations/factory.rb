# frozen_string_literal: true

module Interop
  module Integrations
    class Factory < Base
      class << self
        def key
          "factory"
        end

        def display_name
          "Factory"
        end

        def description
          "Factory integration for ingesting managed agent workflow outcomes and comparing PR quality with Paid-native runs."
        end

        def ingestion_protocol
          :webhook
        end

        def supported_features
          %i[external_execution_ingestion outcome_comparison import_prompts import_workflow_policies]
        end

        def agent_type_key
          "factory"
        end

        def normalize_external_metadata(raw_metadata)
          {
            "pipeline_id" => raw_metadata["pipeline_id"],
            "pipeline_version" => raw_metadata["pipeline_version"],
            "stages_completed" => raw_metadata["stages_completed"],
            "durations" => raw_metadata["durations"],
            "quality_score" => raw_metadata.dig("metrics", "quality_score"),
            "review_passed" => raw_metadata.dig("metrics", "review_passed")
          }.compact
        end
      end
    end
  end
end
