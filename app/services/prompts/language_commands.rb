# frozen_string_literal: true

module Prompts
  # Shared language-specific command mappings for test and lint commands.
  # Used by both Prompts::BuildForIssue and Activities::CreateAgentRunActivity.
  #
  # Covers the eight RDR-046 target languages: Ruby, JavaScript, TypeScript,
  # Python, Go, Rust, Elixir, and Swift. Polyglot repos surface more than one
  # command via the #test_commands_for / #lint_commands_for resolvers, which
  # read the language set from +Project#language_profile+ and fall back to the
  # single detected primary language.
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

    # Display fallback shown when no command is configured for a language set.
    NO_TEST_COMMAND = 'echo "No test command configured"'
    NO_LINT_COMMAND = 'echo "No lint command configured"'

    # Detects the primary language for a project, defaulting to Ruby.
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

    # Returns the languages whose test/lint suites should run for a project.
    #
    # Polyglot repos expose multiple languages through the persisted
    # +language_profile+ (a +test_languages+ array, falling back to +languages+).
    # When no profile is present, the single detected primary language is used,
    # preserving the pre-polyglot single-language behavior.
    #
    # @param project [Project]
    # @return [Array<String>] one or more downcased language keys
    def self.test_languages(project)
      profile_languages(project).presence || [ detected_language(project) ]
    end

    # Resolves the test commands for every language in the project's test set,
    # dropping languages that have no command mapping.
    #
    # @param project [Project]
    # @return [Array<String>] test command strings (never empty)
    # @spec POLYGLOT-TEST-003
    def self.test_commands_for(project)
      commands_for(project, LANGUAGE_TEST_COMMANDS, NO_TEST_COMMAND)
    end

    # Resolves the lint commands for every language in the project's test set.
    #
    # @param project [Project]
    # @return [Array<String>] lint command strings (never empty)
    def self.lint_commands_for(project)
      commands_for(project, LANGUAGE_LINT_COMMANDS, NO_LINT_COMMAND)
    end

    # Formats one or more commands for display inside an agent prompt. A single
    # command renders unchanged (the surrounding prompt template wraps it in
    # backticks); a polyglot set joins commands with ", then " so each language's
    # suite is named within the same inline span.
    #
    # @param commands [Array<String>, String]
    # @return [String]
    def self.format_for_prompt(commands)
      Array(commands).join(", then ")
    end

    # Reads the configured language set from the persisted profile without a
    # detected-language fallback. Returns an empty array when no profile or no
    # language list is present, so callers can distinguish "polyglot" from
    # "single detected language".
    def self.profile_languages(project)
      profile = project.language_profile if project.respond_to?(:language_profile)
      return [] unless profile.is_a?(Hash)

      languages = profile["test_languages"].presence || profile["languages"]
      Array(languages).map { |language| language.to_s.strip.downcase }.reject(&:blank?)
    end
    private_class_method :profile_languages

    def self.commands_for(project, map, fallback)
      commands = test_languages(project).filter_map { |language| map[language] }
      commands.empty? ? [ fallback ] : commands
    end
    private_class_method :commands_for
  end
end
