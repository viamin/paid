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

        1. Install dependencies (`bundle install`, `yarn install`, etc.)
        #{setup_database_instruction}
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
        #{available_services_section}#{no_infrastructure_section}
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

    def setup_database_instruction
      if project.service_containers.any?
        "   Run `bin/rails db:prepare` to set up the database (DATABASE_URL is already configured)."
      else
        "   Do NOT run `bin/setup`, `db:prepare`, or `db:migrate` — no database is available in this environment."
      end
    end

    def no_infrastructure_section
      return "" if project.service_containers.any?

      <<~SECTION

        # Environment Constraints

        You are running in an isolated container WITHOUT database services.
        Do NOT attempt to install PostgreSQL, Redis, or any other infrastructure service.
        Do NOT run `bin/setup`, `bin/rails db:prepare`, `bin/rails db:migrate`, or `initdb`.
        If a task requires database access and none is available, implement the code changes
        and write tests that use mocks or factories, but do not attempt to start a database server.
      SECTION
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
        "- PostgreSQL is available via the `DATABASE_URL` environment variable."
      elsif sc.image.include?("redis")
        "- Redis is available via the `REDIS_URL` environment variable."
      elsif sc.image.include?("selenium") || sc.image.include?("chromium")
        "- Selenium/Chromium is available via the `SELENIUM_URL` environment variable."
      else
        "- #{sc.name} is available at host `#{sc.name}` on port #{sc.port}."
      end
    end
  end
end
