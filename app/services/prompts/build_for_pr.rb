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

    def build
      sections = []
      sections << task_section
      sections << issue_requirements_section if issue
      sections << merge_conflicts_section unless rebase_succeeded
      sections << ci_failures_section if failing_checks.any?
      sections << code_review_section if unresolved_threads.any?
      sections << conversation_section if trusted_comments.any?
      sections << instructions_section
      sections << rules_section
      sections.join("\n")
    end

    private

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
        "- **#{c.user.login}**: #{c.body}"
      end.join("\n")

      <<~SECTION
        # Conversation Comments

        Recent comments from project collaborators:

        #{comment_text}

        Address any actionable requests in these comments.
      SECTION
    end

    def instructions_section
      priorities = []
      priorities << "Resolve merge conflicts" unless rebase_succeeded
      priorities << "Fix CI failures" if failing_checks.any?
      priorities << "Close implementation gaps against the linked issue" if issue
      priorities << "Address code review comments" if unresolved_threads.any?
      priorities << "Address conversation comments" if trusted_comments.any?
      priority_list = priorities.each_with_index.map { |p, i| "#{i + 1}. #{p}" }.join("\n")

      <<~SECTION
        # Instructions

        Priority order:
        #{priority_list}

        Steps:
        1. Set up the project first — install dependencies (`bundle install`, `npm install`, etc.)
        2. Work through the priorities above in order
        3. Run lint and fix any violations: `#{lint_command}`
        4. Run the test suite and fix any failures: `#{test_command}`
        5. Commit your changes with a descriptive message

        **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
        If the commit is rejected, read the error output carefully, fix the issues, and commit again.
        Keep iterating until the commit succeeds. Do not leave uncommitted changes.

        When you're done, commit all your changes. Do not push.
      SECTION
    end

    def rules_section
      <<~SECTION
        # Rules — you MUST follow these

        - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
        - **Never use `--no-verify`** or any flag that skips git hooks.
        - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
        - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
        - Work within the existing codebase style and conventions
        - Do not modify unrelated files
        - Focus on completing the specific tasks listed above
      SECTION
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
        comments = github_client.issue_comments(project.full_name, pr_number)
        comments.select { |c| project.trusted_github_user?(c.user&.login) }
      rescue GithubClient::Error
        []
      end
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
