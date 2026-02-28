# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on a GitHub issue.
  #
  # @example
  #   prompt = Prompts::BuildForIssue.call(issue: issue, project: project)
  #   # => "# Task\n\nYou are working on..."
  class BuildForIssue
    class UntrustedIssueError < StandardError; end

    # Kept for backwards compatibility with existing references
    LANGUAGE_TEST_COMMANDS = LanguageCommands::LANGUAGE_TEST_COMMANDS
    LANGUAGE_LINT_COMMANDS = LanguageCommands::LANGUAGE_LINT_COMMANDS

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
        4. Run lint and fix any violations: `#{lint_command}`
        5. Run the test suite and fix any failures: `#{test_command}`
        6. Commit your changes with a descriptive message

        **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
        If the commit is rejected, read the error output carefully, fix the issues, and commit again.
        Keep iterating until the commit succeeds. Do not leave uncommitted changes.

        # Rules — you MUST follow these

        - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
        - **Never use `--no-verify`** or any flag that skips git hooks.
        - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
        - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
        - Work within the existing codebase style and conventions
        - Do not modify unrelated files
        - Focus on completing the specific task in the issue

        When you're done, commit all your changes. Do not push.
        #{available_services_section}
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
      @detected_language ||= LanguageCommands.detected_language(project)
    end

    def available_services_section
      containers = project.service_containers.to_a
      return "" if containers.empty?

      lines = containers.map { |sc| service_description(sc) }

      <<~SECTION

        # Available Services

        The following services are already running and available:
        #{lines.join("\n")}

        Do NOT install or build these services from source. They are already running.
        Use the environment variables above to connect.
      SECTION
    end

    def service_description(sc)
      if sc.image.include?("postgres")
        user = sc.env["POSTGRES_USER"] || "agent"
        pass = sc.env["POSTGRES_PASSWORD"] || "agent"
        db = sc.env["POSTGRES_DB"] || "agent_test"
        "- PostgreSQL: host=#{sc.name}, port=#{sc.port}, user=#{user}, password=#{pass}, database=#{db}\n  DATABASE_URL is already set in your environment."
      elsif sc.image.include?("redis")
        "- Redis: host=#{sc.name}, port=#{sc.port}\n  REDIS_URL is already set in your environment."
      elsif sc.image.include?("selenium") || sc.image.include?("chromium")
        "- Selenium/Chromium: host=#{sc.name}, port=#{sc.port}\n  SELENIUM_URL is already set in your environment."
      else
        "- #{sc.name}: host=#{sc.name}, port=#{sc.port}"
      end
    end
  end
end
