# frozen_string_literal: true

module Interop
  module Integrations
    class Devin < Base
      class << self
        def key
          "devin"
        end

        def display_name
          "Devin"
        end

        def description
          "Devin integration for ingesting autonomous agent execution outcomes and comparing with Paid-native agent runs."
        end

        def ingestion_protocol
          :api_poll
        end

        def supported_features
          %i[external_execution_ingestion outcome_comparison import_prompts import_workflow_policies]
        end

        def agent_type_key
          "devin"
        end

        def normalize_external_metadata(raw_metadata)
          {
            "session_id" => raw_metadata["session_id"],
            "task_type" => raw_metadata["task_type"],
            "environment" => raw_metadata["environment"],
            "steps_completed" => raw_metadata["steps_completed"],
            "tools_used" => raw_metadata["tools_used"],
            "error_count" => raw_metadata.dig("metrics", "error_count"),
            "success_rate" => raw_metadata.dig("metrics", "success_rate")
          }.compact
        end
      end
    end
  end
end
