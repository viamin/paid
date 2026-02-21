# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on a GitHub issue.
  #
  # @example
  #   prompt = Prompts::BuildForIssue.call(issue: issue, project: project)
  #   # => "# Task\n\nYou are working on..."
  class BuildForIssue
    class UntrustedIssueError < StandardError; end

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
      raise UntrustedIssueError, "Cannot build prompt for issue from untrusted user: #{issue.github_creator_login}" unless issue.trusted?

      <<~PROMPT
        # Task

        You are working on the following GitHub issue:

        **#{issue.title}** (##{issue.github_number})

        #{issue.body}

        # Instructions

        1. Set up the project first — install dependencies (`bundle install`, `npm install`, etc.)
        2. Analyze the issue and understand what needs to be done
        3. Make the necessary code changes
        4. Run lint and fix any violations BEFORE committing: `#{lint_command}`
        5. Run the test suite and fix any failures BEFORE committing: `#{test_command}`
        6. Commit your changes with a descriptive message

        # Rules — you MUST follow these

        - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
        - **Never use `--no-verify`** or any flag that skips git hooks in your commits.
        - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
        - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
        - Work within the existing codebase style and conventions
        - Do not modify unrelated files
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

      # Default to Ruby when detected_language is unavailable
      "ruby"
    end
  end
end
