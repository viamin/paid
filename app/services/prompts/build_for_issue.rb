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

      # Rules — you MUST follow these

      - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
      - **Never use `--no-verify`** or any flag that skips git hooks.
      - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
      - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
      - Work within the existing codebase style and conventions
      - Do not modify unrelated files
      - Focus on completing the specific task in the issue

      When you're done, commit all your changes. Do not push.
    PROMPT

    # Kept for backwards compatibility with existing references
    LANGUAGE_TEST_COMMANDS = LanguageCommands::LANGUAGE_TEST_COMMANDS
    LANGUAGE_LINT_COMMANDS = LanguageCommands::LANGUAGE_LINT_COMMANDS

    # Default limits used when user settings are unavailable.
    # Runtime code resolves per-user values via UserSetting.
    DEFAULT_MAX_COMMENTS = 20
    DEFAULT_MAX_COMMENT_LENGTH = 2000

    attr_reader :issue, :project, :github_client, :agent_run

    def initialize(issue:, project:, github_client: nil, agent_run: nil)
      @issue = issue
      @project = project
      @github_client = github_client
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).build
    end

    def self.service_environment_section_for(project:, include_setup_instruction: true)
      ServiceContainerSections.service_environment_section_for(
        project: project,
        include_setup_instruction: include_setup_instruction
      )
    end

    def build
      raise UntrustedIssueError, "Cannot build prompt for issue from untrusted user: #{issue.github_creator_login}" unless issue.trusted?

      vars = {
        title: issue.title,
        issue_number: issue.github_number.to_s,
        body: issue.body.to_s,
        lint_command: lint_command,
        test_command: test_command,
        setup_database_instruction: setup_database_instruction
      }

      rendered = Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: project,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      )

      # Dynamic sections are composed in code and appended to the rendered
      # template so the template stays readable in the prompts UI.
      base_prompt = [
        rendered,
        conversation_section.presence,
        service_environment_section.presence
      ].compact.join("\n\n")

      with_knowledge = inject_knowledge_context(base_prompt)
      with_style_guides = StyleGuides::InjectIntoPrompt.call(prompt: with_knowledge, project: project)
      ProjectConventions::InjectIntoPrompt.call(prompt: with_style_guides, project: project)
    end

    # Fetches and formats trusted issue comments as a prompt section.
    # Extracted as a class method so CreateAgentRunActivity can append
    # this section to rendered PromptVersion custom_prompts, avoiding
    # the effective_prompt bypass described in the review.
    def self.conversation_section_for(project:, issue:, github_client: nil)
      return "" unless github_client

      settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
      max_comments = settings&.max_prompt_comments || DEFAULT_MAX_COMMENTS
      max_length = settings&.max_comment_length || DEFAULT_MAX_COMMENT_LENGTH

      comments = fetch_trusted_comments(
        github_client: github_client,
        repo: project.full_name,
        number: issue.github_number,
        project: project,
        max_comments: max_comments
      )
      format_conversation_section(comments, max_comment_length: max_length)
    end

    def self.fetch_trusted_comments(github_client:, repo:, number:, project:, max_comments: DEFAULT_MAX_COMMENTS)
      return [] if max_comments <= 0
      all_comments = github_client.issue_comments(repo, number)
      trusted = []
      all_comments.reverse_each do |c|
        next unless project.trusted_github_user?(c.user&.login)
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

    private

    def conversation_section
      self.class.conversation_section_for(
        project: project, issue: issue, github_client: github_client
      )
    end

    def inject_knowledge_context(prompt)
      bundle = Knowledge::ContextBundle::Build.call(issue: issue, project: project, agent_run: agent_run)
      return prompt if bundle[:content].blank?

      "#{prompt}\n#{bundle[:content]}\n"
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
