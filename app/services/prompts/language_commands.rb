# frozen_string_literal: true

module Prompts
  # Shared language-specific command mappings for test and lint commands.
  # Used by both Prompts::BuildForIssue and Activities::CreateAgentRunActivity.
  module LanguageCommands
    LANGUAGE_TEST_COMMANDS = {
      "ruby" => "bundle exec rspec",
      "javascript" => "npm test",
      "typescript" => "npm test",
      "python" => "pytest",
      "go" => "go test ./...",
      "rust" => "cargo test"
    }.freeze

    LANGUAGE_LINT_COMMANDS = {
      "ruby" => "bundle exec rubocop",
      "javascript" => "npm run lint",
      "typescript" => "npm run lint",
      "python" => "ruff check .",
      "go" => "golangci-lint run",
      "rust" => "cargo clippy"
    }.freeze

    DEFAULT_LANGUAGE = "ruby"

    # Detects the language for a project, defaulting to Ruby.
    #
    # @param project [Project] The project to detect language for
    # @return [String] The detected language identifier
    def self.detected_language(project)
      if project.respond_to?(:detected_language) && project.detected_language.present?
        project.detected_language
      else
        DEFAULT_LANGUAGE
      end
    end
  end
end
