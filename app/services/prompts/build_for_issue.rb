# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on a GitHub issue.
  #
  # @example
  #   prompt = Prompts::BuildForIssue.call(issue: issue, project: project)
  #   # => "# Task\n\nYou are working on..."
  class BuildForIssue
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

    attr_reader :issue, :project

    def initialize(issue:, project:)
      @issue = issue
      @project = project
    end

    def self.call(...)
      new(...).build
    end

    def build
      <<~PROMPT
        # Task

        You are working on the following GitHub issue:

        **#{issue.title}** (##{issue.github_number})

        #{issue.body}

        # Instructions

        1. Analyze the issue and understand what needs to be done
        2. Make the necessary code changes
        3. Ensure tests pass (run `#{test_command}` if available)
        4. Ensure linting passes (run `#{lint_command}` if available)
        5. Commit your changes with a descriptive message

        # Important

        - Work within the existing codebase style and conventions
        - Do not modify unrelated files
        - If you're unsure about something, leave a comment in the code
        - Focus on completing the specific task in the issue

        When you're done, commit all your changes. Do not push.
      PROMPT
    end

    private

    def test_command
      LANGUAGE_TEST_COMMANDS.fetch(detected_language, "echo \"No test command configured\"")
    end

    def lint_command
      LANGUAGE_LINT_COMMANDS.fetch(detected_language, "echo \"No lint command configured\"")
    end

    def detected_language
      @detected_language ||= detect_language
    end

    def detect_language
      return project.detected_language if project.respond_to?(:detected_language) && project.detected_language.present?

      # Infer from project name or repo conventions
      "ruby"
    end
  end
end
