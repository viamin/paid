# frozen_string_literal: true

module Interop
  module Integrations
    class GithubCopilot < Base
      class << self
        def key
          "github_copilot"
        end

        def display_name
          "GitHub Copilot"
        end

        def description
          "GitHub Copilot integration for observing agent-assisted coding sessions and comparing outcomes with Paid-native runs."
        end

        def ingestion_protocol
          :webhook
        end

        def supported_features
          %i[external_execution_ingestion outcome_comparison import_prompts]
        end

        def agent_type_key
          "copilot"
        end

        def normalize_external_metadata(raw_metadata)
          {
            "session_type" => raw_metadata["session_type"],
            "editor" => raw_metadata["editor"],
            "language" => raw_metadata["language"],
            "repository" => raw_metadata["repository"],
            "suggestions_accepted" => raw_metadata.dig("metrics", "suggestions_accepted"),
            "suggestions_offered" => raw_metadata.dig("metrics", "suggestions_offered"),
            "lines_generated" => raw_metadata.dig("metrics", "lines_generated")
          }.compact
        end
      end
    end
  end
end
