# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on a GitHub issue.
  #
  # @example
  #   prompt = Prompts::BuildForIssue.call(issue: issue, project: project)
  #   # => "# Task\n\nYou are working on..."
  class BuildForIssue
    include ServiceContainerSections

    class UntrustedIssueError < StandardError; end

    # Kept for backwards compatibility with existing references
    LANGUAGE_TEST_COMMANDS = LanguageCommands::LANGUAGE_TEST_COMMANDS
    LANGUAGE_LINT_COMMANDS = LanguageCommands::LANGUAGE_LINT_COMMANDS

    attr_reader :issue, :project, :github_client

    def initialize(issue:, project:, github_client: nil)
      @issue = issue
      @project = project
      @github_client = github_client
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
        #{conversation_section}
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

    def conversation_section
      return "" unless trusted_comments.any?

      comment_text = trusted_comments.map do |c|
        "- **#{c.user.login}**: #{c.body}"
      end.join("\n")

      "\n# Conversation Comments\n\n" \
        "Comments from project collaborators:\n\n" \
        "#{comment_text}\n\n" \
        "Address any actionable requests in these comments.\n"
    end

    def trusted_comments
      @trusted_comments ||= begin
        if github_client
          comments = github_client.issue_comments(project.full_name, issue.github_number)
          comments.select { |c| project.trusted_github_user?(c.user&.login) }
        else
          []
        end
      rescue GithubClient::Error
        []
      end
    end

    def test_command
      LANGUAGE_TEST_COMMANDS.fetch(detected_language, "echo \"No test command configured\"")
    end

    def lint_command
      LANGUAGE_LINT_COMMANDS.fetch(detected_language, "echo \"No lint command configured\"")
    end

    def detected_language
      @detected_language ||= LanguageCommands.detected_language(project)
    end

    # Service container methods (setup_database_instruction, no_infrastructure_section,
    # available_services_section, etc.) are provided by ServiceContainerSections
  end
end
