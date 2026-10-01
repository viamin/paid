# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on a GitHub issue.
  #
  # @example
  #   prompt = Prompts::BuildForIssue.call(issue: issue, project: project)
  #   # => "# Task\n\nYou are working on..."
  class BuildForIssue
    class UntrustedIssueError < StandardError; end

    PROMPT_SLUG = "coding.issue_implementation"

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~'PROMPT'
      # Task

      You are working on the following GitHub issue:

      **{{title}}** (#{{issue_number}})

      {{body}}

      # Instructions

      1. Install dependencies (`bundle install`, `yarn install`, etc.)
      {{setup_database_instruction}}
      2. Analyze the issue and understand what needs to be done
      3. Make the necessary code changes
      4. Run lint and fix any violations: `{{lint_command}}`
      5. Run the test suite and fix any failures: `{{test_command}}`
      6. Commit your changes with a descriptive message

      **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
      If the commit is rejected, read the error output carefully, fix the issues, and commit again.
      Keep iterating until the commit succeeds. Do not leave uncommitted changes.
    PROMPT

    # Kept for backwards compatibility with existing references
    LANGUAGE_TEST_COMMANDS = LanguageCommands::LANGUAGE_TEST_COMMANDS
    LANGUAGE_LINT_COMMANDS = LanguageCommands::LANGUAGE_LINT_COMMANDS

    # Default limits used when user settings are unavailable.
    # Runtime code resolves per-user values via UserSetting.
    DEFAULT_MAX_COMMENTS = 20
    DEFAULT_MAX_COMMENT_LENGTH = 2000

    def self.call(...)
      new(...).build
    end

    attr_reader :issue, :project, :github_client, :agent_run

    def initialize(issue:, project:, github_client: nil, agent_run: nil)
      @issue = issue
      @project = project
      @github_client = github_client
      @agent_run = agent_run
    end

    def self.service_environment_section_for(project:, include_setup_instruction: true)
      ServiceContainerSections.service_environment_section_for(
        project: project,
        include_setup_instruction: include_setup_instruction
      )
    end

    def self.service_environment_section_render_for(project:, include_setup_instruction: true)
      ServiceContainerSections.service_environment_section_render_for(
        project: project,
        include_setup_instruction: include_setup_instruction
      )
    end

    def build
      # @spec PROMPT-ASSEMBLY-014
      PromptAssembly::BuildIssuePrompt.call(
        issue: issue,
        project: project,
        github_client: github_client,
        agent_run: agent_run
      ).text
    end

    # Fetches and formats trusted issue comments as a prompt section.
    # Extracted as a class method so CreateAgentRunActivity can append
    # this section to rendered PromptVersion custom_prompts, avoiding
    # the effective_prompt bypass described in the review.
    # When +issue_comments+ is supplied (e.g. by the instance builder, which
    # shares one fetch with #clarifying_answers_section), the network round-trip
    # is skipped and the supplied comments are filtered in place.
    def self.conversation_section_for(project:, issue:, github_client: nil, issue_comments: nil)
      return "" unless github_client

      settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
      max_comments = settings&.max_prompt_comments || DEFAULT_MAX_COMMENTS
      max_length = settings&.max_comment_length || DEFAULT_MAX_COMMENT_LENGTH

      comments = fetch_trusted_comments(
        github_client: github_client,
        repo: project.full_name,
        number: issue.github_number,
        project: project,
        max_comments: max_comments,
        comments: issue_comments
      )
      format_conversation_section(comments, max_comment_length: max_length)
    end

    # When +comments+ is supplied, the GitHub fetch is skipped so callers that
    # already hold the comment list (e.g. #issue_comments) don't pay for a
    # second round-trip. Without it the list is fetched as before.
    # @spec PROMPT-ASSEMBLY-007
    def self.fetch_trusted_comments(github_client:, repo:, number:, project:, max_comments: DEFAULT_MAX_COMMENTS, comments: nil)
      return [] if max_comments <= 0
      all_comments = comments || github_client.issue_comments(repo, number)
      trusted = []
      all_comments.reverse_each do |c|
        next unless PromptAssembly::Trust.human_trusted?(project, c.user&.login)
        trusted << c
        break if trusted.size == max_comments
      end
      trusted.reverse
    rescue GithubClient::Error
      []
    end

    def self.format_conversation_section(comments, max_comment_length: DEFAULT_MAX_COMMENT_LENGTH)
      return "" unless comments.any?

      comment_text = comments.map do |c|
        body = c.body.to_s
        body = "#{body[0, max_comment_length]}… [truncated]" if body.length > max_comment_length
        "- **#{c.user.login}**: #{body}"
      end.join("\n")

      (
        "\n# Conversation Comments\n\n" \
          "Comments from project collaborators:\n\n" \
          "#{comment_text}\n\n" \
          "Address any actionable requests in these comments.\n"
      ).delete("\u0000")
    end
  end
end
