# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on an existing pull request.
  #
  # Gathers CI failures, review threads, conversation comments, and
  # optionally linked issue requirements to produce a comprehensive prompt
  # that tells the agent to rebase, fix CI, address reviews, and push.
  #
  # @example
  #   prompt = Prompts::BuildForPr.call(
  #     project: project,
  #     pr_number: 42,
  #     github_client: client,
  #     rebase_succeeded: true
  #   )
  class BuildForPr
    include ServiceContainerSections

    attr_reader :project, :pr_number, :github_client, :rebase_succeeded,
                :lint_command, :test_command, :issue

    def initialize(project:, pr_number:, github_client:, rebase_succeeded:,
                   lint_command: nil, test_command: nil, issue: nil)
      @project = project
      @pr_number = pr_number
      @github_client = github_client
      @rebase_succeeded = rebase_succeeded
      @lint_command = lint_command || detected_lint_command
      @test_command = test_command || detected_test_command
      @issue = issue
    end

    def self.call(...)
      new(...).build
    end

    PROMPT_SLUG = "coding.pr_review_rebase"

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~'PROMPT'
      # Instructions

      Priority order:
      {{priority_list}}

      Steps:
      1. Install dependencies (`bundle install`, `yarn install`, etc.)
      {{setup_database_instruction}}
      2. Work through the priorities above in order
      3. Proactive scan: After making your changes, review the **entire diff** you are
         about to commit{{review_scan_instruction}}. Look for missing guard clauses,
         insufficient input validation, unhandled edge cases, missing tests, unclear
         naming, and style inconsistencies. Fix every issue you find — the goal is
         zero new review rounds for problems you could have caught yourself.
      4. Run lint and fix any violations: `{{lint_command}}`
      5. Run the test suite and fix any failures: `{{test_command}}`
      6. Commit your changes with a descriptive message

      **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
      If the commit is rejected, read the error output carefully, fix the issues, and commit again.
      Keep iterating until the commit succeeds. Do not leave uncommitted changes.

      When you're done, commit all your changes. Do not push.

      # Rules — you MUST follow these

      - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
      - **Never use `--no-verify`** or any flag that skips git hooks.
      - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
      - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
      - Work within the existing codebase style and conventions
      - Do not modify unrelated files
      - Focus on completing the specific tasks listed above
    PROMPT

    def build
      sections = []
      sections << task_section
      sections << issue_requirements_section if linked_issue?
      sections << merge_conflicts_section unless rebase_succeeded
      sections << ci_failures_section if failing_checks.any?
      sections << code_review_section if unresolved_threads.any?
      sections << conversation_section if trusted_comments.any?
      sections << instructions_and_rules_shell
      sections << service_environment_section
      base_prompt = sections.join("\n").delete("\x00")

      StyleGuides::InjectIntoPrompt.call(prompt: base_prompt, project: project)
    end

    private

    def instructions_and_rules_shell
      vars = {
        priority_list: priority_list,
        setup_database_instruction: setup_database_instruction,
        review_scan_instruction: review_scan_instruction,
        lint_command: lint_command,
        test_command: test_command
      }

      Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: project,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      )
    end

    def priority_list
      priorities = []
      priorities << "Resolve merge conflicts" unless rebase_succeeded
      priorities << "Fix CI failures" if failing_checks.any?
      priorities << "Close implementation gaps against the linked issue" if linked_issue?
      priorities << "Address code review comments" if unresolved_threads.any?
      priorities << "Address conversation comments" if trusted_comments.any?
      priorities.each_with_index.map { |p, i| "#{i + 1}. #{p}" }.join("\n")
    end

    # Returns true when a separate issue is linked (not the PR's own Issue record).
    # PR follow-up runs pass the PR's Issue as `issue`, which duplicates the
    # PR body already present in task_section. Skip it in that case.
    def linked_issue?
      issue.present? && !issue.is_pull_request?
    end

    def pr_data
      @pr_data ||= github_client.pull_request(project.full_name, pr_number)
    end

    def base_branch
      pr_data.base.ref
    end

    def task_section
      <<~SECTION
        # Task

        You are working on an existing pull request:

        **#{pr_data.title}** (##{pr_number})

        Base branch: `#{base_branch}`

        #{pr_data.body}
      SECTION
    end

    def issue_requirements_section
      <<~SECTION
        # Issue Requirements

        This PR is linked to the following issue:

        **#{issue.title}** (##{issue.github_number})

        #{issue.body}

        Evaluate whether the current PR changes fully implement the issue requirements.
        Close any implementation or testing gaps you find.
      SECTION
    end

    def merge_conflicts_section
      <<~SECTION
        # Merge Conflicts

        Automatic rebase against `#{base_branch}` failed due to conflicts.
        Run `git merge origin/#{base_branch}` and resolve all conflicts.
        Ensure the merged result compiles and passes all tests.
      SECTION
    end

    def ci_failures_section
      names = failing_checks.map { |c| "- #{c[:name]} (#{c[:conclusion]})" }.join("\n")

      <<~SECTION
        # CI Failures

        The following CI checks are failing:

        #{names}

        Reproduce these failures locally using the lint and test commands below.
        Fix the underlying issues — do not skip or disable checks.
      SECTION
    end

    def code_review_section
      thread_text = unresolved_threads.map do |thread|
        comments = thread[:comments].map do |c|
          location = [ c[:path], c[:line] ].compact.join(":")
          "  - **#{c[:author]}**#{" (#{location})" if location.present?}: #{c[:body]}"
        end.join("\n")

        "**Thread** (#{thread[:comments].first&.dig(:path) || "general"}):\n#{comments}"
      end.join("\n\n")

      <<~SECTION
        # Code Review Comments

        The following review threads are unresolved:

        #{thread_text}

        Address each thread: fix the code if the reviewer is correct, or explain
        your reasoning in a code comment if you disagree. Do not ignore review feedback.
      SECTION
    end

    def conversation_section
      comment_text = trusted_comments.map do |c|
        body = c.body.to_s
        body = "#{body[0, max_comment_length]}… [truncated]" if body.length > max_comment_length
        "- **#{c.user.login}**: #{body}"
      end.join("\n")

      <<~SECTION
        # Conversation Comments

        Recent comments from project collaborators:

        #{comment_text}

        Address any actionable requests in these comments.
      SECTION
    end

    # When reviewers have flagged specific issues, tell the agent to scan for
    # the same class of problem across the whole diff — not just the flagged lines.
    def review_scan_instruction
      return "" unless unresolved_threads.any?

      ". Pay special attention to the same classes of issues the reviewers " \
        "raised — if they flagged one instance, scan for similar problems " \
        "elsewhere in your changes"
    end

    # Memoized data fetchers

    def failing_checks
      @failing_checks ||= begin
        checks = github_client.check_runs_for_ref(project.full_name, pr_data.head.sha)
        checks.reject { |c| %w[success skipped neutral].include?(c[:conclusion].to_s) }
      rescue GithubClient::Error
        []
      end
    end

    def unresolved_threads
      @unresolved_threads ||= begin
        threads = github_client.review_threads(project.full_name, pr_number)
        threads.reject { |t| t[:is_resolved] }
      rescue GithubClient::Error
        []
      end
    end

    def trusted_comments
      @trusted_comments ||= begin
        comments = github_client.recent_issue_comments(project.full_name, pr_number, pages: 2)
        comments
          .select { |c| project.trusted_github_user?(c.user&.login) }
          .last(max_prompt_comments)
      rescue GithubClient::Error
        []
      end
    end

    def user_settings
      @user_settings ||= AgentRuns::UserSettingsResolver.call(project: project, strict: false)
    end

    def max_prompt_comments
      user_settings&.max_prompt_comments || BuildForIssue::DEFAULT_MAX_COMMENTS
    end

    def max_comment_length
      user_settings&.max_comment_length || BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH
    end

    def detected_language
      @detected_language ||= begin
        lang = project.detected_language if project.respond_to?(:detected_language)
        lang.presence || "ruby"
      end
    end

    def detected_lint_command
      BuildForIssue::LANGUAGE_LINT_COMMANDS.fetch(detected_language, "echo \"No lint command configured\"")
    end

    def detected_test_command
      BuildForIssue::LANGUAGE_TEST_COMMANDS.fetch(detected_language, "echo \"No test command configured\"")
    end
  end
end
