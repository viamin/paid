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
      "rust" => "cargo test",
      "elixir" => "mix test",
      "swift" => "swift test"
    }.freeze

    LANGUAGE_LINT_COMMANDS = {
      "ruby" => "bundle exec rubocop",
      "javascript" => "npm run lint",
      "typescript" => "npm run lint",
      "python" => "ruff check .",
      "go" => "golangci-lint run",
      "rust" => "cargo clippy",
      "elixir" => "mix credo --strict",
      "swift" => "swift format lint --recursive ."
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

    def self.test_languages(project) # @spec POLYGLOT-TEST-003
      languages = if project.respond_to?(:test_languages)
        Array(project.test_languages)
      else
        []
      end

      languages = [ detected_language(project) ] if languages.empty?
      languages.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def self.test_command(project) # @spec POLYGLOT-TEST-003
      command_for(project, LANGUAGE_TEST_COMMANDS, "echo \"No test command configured\"")
    end

    def self.lint_command(project) # @spec POLYGLOT-TEST-003
      command_for(project, LANGUAGE_LINT_COMMANDS, "echo \"No lint command configured\"")
    end

    def self.command_for(project, mapping, fallback)
      commands = test_languages(project).filter_map { |language| mapping[language] }.uniq
      commands.presence&.join(" && ") || fallback
    end
  end
end
