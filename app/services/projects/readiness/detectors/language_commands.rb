# frozen_string_literal: true

module Projects
  module Readiness
    module Detectors
      # Fallback detector covering every language `Prompts::LanguageCommands`
      # already models (RDR-046's eight target languages). Always applicable
      # so a project whose ecosystem no other detector claims still gets a
      # test-directory/test-command answer instead of silently passing.
      class LanguageCommands < Detector
        TEST_DIR_CANDIDATES = {
          "ruby" => %w[spec test],
          "javascript" => %w[test tests __tests__ spec],
          "typescript" => %w[test tests __tests__ spec],
          "python" => %w[tests test],
          "go" => %w[test],
          "rust" => %w[tests test],
          "elixir" => %w[test],
          "swift" => %w[Tests test tests]
        }.freeze
        DEFAULT_CANDIDATES = %w[spec test tests].freeze

        def self.applicable?(project:, repo_path:)
          true
        end

        def ecosystem
          @ecosystem ||= Prompts::LanguageCommands.detected_language(project)
        end

        def test_directory_candidates
          TEST_DIR_CANDIDATES.fetch(ecosystem, DEFAULT_CANDIDATES)
        end

        def test_directory?
          test_directory_candidates.any? { |dir| Dir.exist?(File.join(repo_path, dir)) }
        end

        def test_command_configured?
          Prompts::LanguageCommands.test_commands_for(project) != [ Prompts::LanguageCommands::NO_TEST_COMMAND ]
        end

        def test_command_description
          Prompts::LanguageCommands.format_for_prompt(Prompts::LanguageCommands.test_commands_for(project))
        end
      end
    end
  end
end
