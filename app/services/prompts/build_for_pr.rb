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

    DEFAULT_MAX_COMMENTS = BuildForIssue::DEFAULT_MAX_COMMENTS
    DEFAULT_MAX_COMMENT_LENGTH = BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH
    GITHUB_COMMENTS_PER_PAGE = 100
    MAX_RECENT_COMMENT_PAGES = 10
    ALREADY_ADDRESSED_MARKER = "PAID_REVIEW_THREADS_ALREADY_ADDRESSED"

    attr_reader :project, :pr_number, :github_client, :rebase_succeeded,
                :lint_command, :test_command, :issue, :prompt_version, :focus,
                :agent_run

    def initialize(project:, pr_number:, github_client:, rebase_succeeded:,
                   lint_command: nil, test_command: nil, issue: nil, prompt_version: nil,
                   focus: "general", agent_run: nil)
      @project = project
      @pr_number = pr_number
      @github_client = github_client
      @rebase_succeeded = rebase_succeeded
      @lint_command = lint_command || detected_lint_command
      @test_command = test_command || detected_test_command
      @issue = issue
      @prompt_version = prompt_version
      @focus = focus.presence || "general"
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).build
    end

    def self.service_environment_section_render_for(project:, include_setup_instruction: false)
      ServiceContainerSections.service_environment_section_render_for(
        project: project,
        include_setup_instruction: include_setup_instruction
      )
    end

    # Production-parity filter so REPLs/scripts get the same comments the live PR prompt does.
    def self.select_trusted_comments(comments, project:)
      comments.select do |comment|
        project.trusted_github_user?(comment.user&.login) &&
          !paid_generated_pr_comment?(comment.body)
      end
    end

    def self.paid_generated_pr_comment?(body)
      Activities::CompleteExistingPrRunActivity.agent_update_comment?(body) ||
        body.to_s.include?(Activities::MarkEscalatedActivity::COMMENT_MARKER)
    end
    private_class_method :paid_generated_pr_comment?

    def includes_review_threads?
      include_section?(:code_review) && review_threads_present?
    end

    def unresolved_review_thread_ids
      return [] unless includes_review_threads?

      unresolved_threads.filter_map { |thread| thread[:id] }
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

      {{already_addressed_instruction}}

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
      sections << issue_requirements_section if include_issue_requirements_section?
      sections << merge_conflicts_section if include_merge_conflicts_section?
      sections << ci_failures_section if include_ci_failures_section?
      sections << code_review_section if includes_review_threads?
      sections << planning_pr_intent_confirmation_section if planning_pr_intent_confirmation_section.present?
      sections << conversation_section if include_conversation_section?
      other_issues = other_issues_section
      sections << other_issues if other_issues.present?
      sections << instructions_and_rules_shell
      sections << service_environment_section
      base_prompt = sections.join("\n").delete("\x00")

      with_style_guides = StyleGuides::InjectIntoPrompt.call(
        prompt: base_prompt,
        project: project,
        agent_run: agent_run,
        source: self.class.name
      )
      with_conventions = ProjectConventions::InjectIntoPrompt.call(prompt: with_style_guides, project: project)
      Lid::InjectIntoPrompt.call(prompt: with_conventions, project: project)
    end

    private

    def instructions_and_rules_shell
      vars = {
        priority_list: priority_list,
        setup_database_instruction: setup_database_instruction,
        review_scan_instruction: review_scan_instruction,
        already_addressed_instruction: already_addressed_instruction,
        lint_command: lint_command,
        test_command: test_command
      }

      return prompt_version.render(vars) if prompt_version.present?

      Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: project,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      )
    end

    def priority_list
      return focused_priority_list if use_focused_priority_list?

      dynamic_priority_list
    end

    def dynamic_priority_list
      priorities = []
      priorities << "Resolve merge conflicts" if merge_conflicts_present?
      priorities << "Fix CI failures" if ci_failures_present?
      priorities << "Close implementation gaps against the linked issue" if issue_requirements_present?
      priorities << "Address code review comments" if review_threads_present?
      priorities << "Address conversation comments" if conversation_comments_present?
      priorities.each_with_index.map { |p, i| "#{i + 1}. #{p}" }.join("\n")
    end

    def focused?
      focus != "general"
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
      names = ci_failure_context.checks.map { |c| "- #{c[:name]} (#{c[:conclusion]})" }.join("\n")
      output = ci_failure_context.output

      <<~SECTION
        # CI Status: FAILING

        The following CI checks are failing on this branch:

        #{names}

        #{ci_failure_output_section(output)}

        #{ci_failure_guidance_section}

        Fix the issue causing these CI failures. Do not skip or disable checks.
      SECTION
    end

    def ci_failure_output_section(output)
      return "No check log output was available from GitHub." if output.blank?

      <<~SECTION
        Error output (pre-processed):

        ```text
        #{output}
        ```
      SECTION
    end

    def ci_failure_guidance_section
      guidance = Prompts::Render.call(
        slug: "ci.failure_guidance",
        project: project,
        variables: {
          failure_type_hints: failure_type_hints,
          workflow_content_section: workflow_content_section
        },
        fallback: -> { fallback_ci_failure_guidance }
      )

      guidance.present? ? guidance : ""
    end

    def fallback_ci_failure_guidance
      section = ""
      section += failure_type_hints if failure_type_hints.present?
      section += "\n\n#{workflow_content_section}" if workflow_content_section.present?
      section
    end

    FAILURE_TYPE_HINTS = {
      database: "This looks like a **database error**. Check that the CI workflow's database " \
                "setup step creates the correct database for the test environment. Compare " \
                "`RAILS_ENV` in the setup step vs the test step — a mismatch can cause the " \
                "database to be created for `development` but tested under `test`.",
      environment: "This looks like an **environment error**. A command or configuration file " \
                   "is missing in CI. Check the CI workflow for missing setup steps or " \
                   "environment variables.",
      dependency: "This looks like a **dependency error**. A gem, package, or library is missing " \
                  "or incompatible. Check the CI workflow's dependency installation step and " \
                  "compare versions with what's expected.",
      service: "This looks like a **service connectivity error**. A required service (database, " \
               "Redis, etc.) is not reachable. Check the CI workflow's service container " \
               "configuration and health checks.",
      timeout: "This looks like a **timeout error**. A step or network request took too long. " \
               "Check the CI workflow for appropriate timeout settings."
    }.freeze

    def failure_type_hints
      types = ci_failure_context.failure_types
      return "" if types.empty?

      hints = types.filter_map { |t| FAILURE_TYPE_HINTS[t] }
      return "" if hints.empty?

      "### Detected failure types: #{types.map(&:to_s).join(', ')}\n\n" + hints.join("\n\n")
    end

    def workflow_content_section
      content = ci_failure_context.workflow_content
      return "" if content.blank?

      "## CI Workflow Configuration\n\nThe following CI workflow files are active on this branch:\n\n#{content}"
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
        "- **#{c.user.login}**: #{truncate_comment_body(c.body.to_s)}"
      end.join("\n")

      <<~SECTION
        # Conversation Comments

        Recent comments from project collaborators:

        #{comment_text}

        Address any actionable requests in these comments.
      SECTION
    end

    def other_issues_section
      return "" unless focused?

      issues = deferred_issue_descriptions
      return "" if issues.empty?

      <<~SECTION
        # Other Issues on This PR (Deferred)

        This PR also has the following issues that are **not** your responsibility this run:
        #{issues.map { |issue| "- #{issue}" }.join("\n")}

        Ignore the "fix forward" directive for these unrelated problems. Follow-up runs will address them.
        Do not attempt to fix these issues. Focus solely on the task described above.
      SECTION
    end

    # @spec LID-PR-CONFIRM-002
    def planning_pr_intent_confirmation_section
      return "" unless includes_review_threads?
      return "" unless planning_pr_confirmation_requested?

      <<~SECTION
        # Intent Confirmation Follow-Up

        This PR appears to be a docs-only LID planning PR. Treat review comments on
        `[inferred]` lines as intent corrections, not ordinary prose edits.

        When a reviewer requests changes on an inferred decision:

        - Replace the `[inferred]` marker with the reviewer's authored rationale.
        - Update the affected LLD, EARS, and any linked Open Questions text on this branch
          so the corrected rationale is consistent everywhere it is load-bearing.
        - Keep comment-only feedback deferable. Approvals confirm any remaining inferred
          decisions that were not corrected in review.
      SECTION
    end

    # When reviewers have flagged specific issues, tell the agent to scan for
    # the same class of problem across the whole diff — not just the flagged lines.
    def review_scan_instruction
      return "" unless includes_review_threads?

      ". Pay special attention to the same classes of issues the reviewers " \
        "raised — if they flagged one instance, scan for similar problems " \
        "elsewhere in your changes"
    end

    def already_addressed_instruction
      return "" unless includes_review_threads?

      "\n\nIf you verify that every unresolved review thread listed above is already " \
        "addressed on the current branch and no code changes are needed, do not " \
        "make a no-op commit. End your final response with a standalone line " \
        "containing exactly `#{ALREADY_ADDRESSED_MARKER}`."
    end

    def include_section?(section)
      return true if general_or_label_action_focus?

      scoped_section_for_focus == section
    end

    def general_or_label_action_focus?
      focus.in?([ "general", "label_action" ])
    end

    def scoped_section_for_focus
      {
        "ci_fix" => :ci_failures,
        "review_feedback" => :code_review,
        "merge_conflict" => :merge_conflicts,
        "conversation" => :conversation,
        "issue_implementation" => :issue_requirements
      }[focus]
    end

    def include_issue_requirements_section?
      include_section?(:issue_requirements) && issue_requirements_present?
    end

    def include_merge_conflicts_section?
      include_section?(:merge_conflicts) && merge_conflicts_present?
    end

    def include_ci_failures_section?
      include_section?(:ci_failures) && ci_failures_present?
    end

    def include_conversation_section?
      include_section?(:conversation) && conversation_comments_present?
    end

    def merge_conflicts_present?
      !rebase_succeeded
    end

    def ci_failures_present?
      ci_failure_context.failing?
    end

    def issue_requirements_present?
      linked_issue?
    end

    def review_threads_present?
      unresolved_threads.any?
    end

    def conversation_comments_present?
      trusted_comments.any?
    end

    def use_focused_priority_list?
      focused_priority_section_present? || focus == "label_action"
    end

    def focused_priority_section_present?
      {
        "ci_fix" => include_ci_failures_section?,
        "review_feedback" => includes_review_threads?,
        "merge_conflict" => include_merge_conflicts_section?,
        "conversation" => include_conversation_section?,
        "issue_implementation" => include_issue_requirements_section?
      }.fetch(focus, false)
    end

    def focused_priority_list
      "1. #{focused_priority_item}"
    end

    def focused_priority_item
      {
        "ci_fix" => "Fix the failing CI checks on this PR",
        "review_feedback" => "Address the unresolved code review comments on this PR",
        "merge_conflict" => "Resolve the merge conflicts on this PR",
        "conversation" => "Address the actionable conversation comments on this PR",
        "issue_implementation" => "Close implementation gaps against the linked issue for this PR",
        "label_action" => "Handle the actionable labels on this PR"
      }.fetch(focus, "Complete the scoped task for this PR")
    end

    def deferred_issue_descriptions
      descriptions = []
      descriptions << "merge conflicts with the base branch" if defer_issue?(:merge_conflicts) && merge_conflicts_present?
      descriptions << "failing CI checks" if defer_issue?(:ci_failures) && ci_failures_present?
      descriptions << "implementation gaps against the linked issue" if defer_issue?(:issue_requirements) && issue_requirements_present?
      descriptions << "unresolved code review comments" if defer_issue?(:code_review) && review_threads_present?
      descriptions << "actionable conversation comments" if defer_issue?(:conversation) && conversation_comments_present?
      descriptions
    end

    def defer_issue?(section)
      focused? && !include_section?(section)
    end

    # Memoized data fetchers

    def failing_checks
      @failing_checks ||= begin
        checks = github_client.check_runs_for_ref(project.full_name, pr_data.head.sha)
        checks.reject { |c| Ci::FailureContext::GREEN_CONCLUSIONS.include?(c[:conclusion].to_s) }
      rescue GithubClient::Error
        []
      end
    end

    def ci_failure_context
      @ci_failure_context ||= Ci::FailureContext.call(
        repo: project.full_name,
        checks: failing_checks,
        github_client: github_client,
        ref: pr_data.head.sha
      )
    end

    def unresolved_threads
      @unresolved_threads ||= begin
        threads = github_client.review_threads(project.full_name, pr_number)
        threads.reject { |t| t[:is_resolved] }
      rescue GithubClient::Error
        []
      end
    end

    def planning_pr_confirmation_requested?
      return false unless Lid::BuildInferenceChecklist.checklist_appended?(pr_data.body)

      Lid::BuildInferenceChecklist.docs_only_planning_pr?(
        body: pr_data.body,
        changed_files: pull_request_files
      )
    end

    def pull_request_files
      @pull_request_files ||= github_client.pull_request_files(project.full_name, pr_number)
    rescue GithubClient::Error
      []
    end

    def trusted_comments
      @trusted_comments ||= begin
        recent_trusted_comments
      rescue GithubClient::Error
        []
      end
    end

    def prompt_comment_settings
      @prompt_comment_settings ||= begin
        settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
        {
          max_comments: settings&.max_prompt_comments || DEFAULT_MAX_COMMENTS,
          max_comment_length: settings&.max_comment_length || DEFAULT_MAX_COMMENT_LENGTH
        }
      end
    end

    def max_prompt_comments
      prompt_comment_settings[:max_comments]
    end

    def max_comment_length
      prompt_comment_settings[:max_comment_length]
    end

    def recent_comment_page_window
      [
        [ (max_prompt_comments.to_f / GITHUB_COMMENTS_PER_PAGE).ceil, 1 ].max,
        MAX_RECENT_COMMENT_PAGES
      ].min
    end

    def recent_trusted_comments
      comments = github_client.recent_issue_comments(project.full_name, pr_number, pages: recent_comment_page_window)
      trusted = select_trusted_comments(comments)
      pages_fetched = recent_comment_page_window

      while trusted.size < max_prompt_comments && pages_fetched < MAX_RECENT_COMMENT_PAGES
        break unless comments.respond_to?(:next_older_page_url) && comments.next_older_page_url

        older_page = github_client.fetch_issue_comment_page(comments.next_older_page_url)
        trusted = select_trusted_comments(older_page) + trusted
        pages_fetched += 1
        comments = older_page
      end

      trusted.last(max_prompt_comments)
    end

    def select_trusted_comments(comments)
      self.class.select_trusted_comments(comments, project: project)
    end

    def truncate_comment_body(body)
      return body if body.length <= max_comment_length

      "#{body[0, max_comment_length]}… [truncated]"
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
