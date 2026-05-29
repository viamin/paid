# frozen_string_literal: true

module Interop
  module Integrations
    class Cursor < Base
      class << self
        def key
          "cursor"
        end

        def display_name
          "Cursor"
        end

        def description
          "Cursor integration for tracking AI-assisted development sessions and comparing PR outcomes with Paid-native runs."
        end

        def ingestion_protocol
          :webhook
        end

        def supported_features
          %i[external_execution_ingestion outcome_comparison import_prompts import_style_guides]
        end

        def agent_type_key
          "cursor"
        end

        def normalize_external_metadata(raw_metadata)
          {
            "session_type" => raw_metadata["session_type"],
            "model" => raw_metadata["model"],
            "composer_version" => raw_metadata["composer_version"],
            "files_modified" => raw_metadata["files_modified"],
            "iterations" => raw_metadata["iterations"],
            "tokens_used" => raw_metadata.dig("metrics", "tokens_used")
          }.compact
        end
      end
    end
  end
end
