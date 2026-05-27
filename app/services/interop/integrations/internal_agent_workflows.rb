# frozen_string_literal: true

module Interop
  module Integrations
    class InternalAgentWorkflows < Base
      class << self
        def key
          "internal_agent_workflows"
        end

        def display_name
          "Internal Agent Workflows"
        end

        def description
          "Integration for ingesting outcomes from existing in-house agent systems to compare with Paid-native execution."
        end

        def ingestion_protocol
          :api_push
        end

        def supported_features
          %i[external_execution_ingestion outcome_comparison import_prompts import_style_guides import_workflow_policies]
        end

        def agent_type_key
          "internal_agent"
        end

        def normalize_external_metadata(raw_metadata)
          {
            "workflow_name" => raw_metadata["workflow_name"],
            "version" => raw_metadata["version"],
            "team" => raw_metadata["team"],
            "run_url" => raw_metadata["run_url"],
            "custom_metrics" => raw_metadata["custom_metrics"]
          }.compact
        end
      end
    end
  end
end
