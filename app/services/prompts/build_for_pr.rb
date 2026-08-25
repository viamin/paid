# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on an existing pull request.
  #
  # Gathers CI failures, review threads, conversation comments, and
  # optionally linked issue requirements to produce a comprehensive prompt
  # that tells the agent to rebase, fix CI, address reviews, and push.
  #
  # Uses the legacy string builder by default. PromptAssembly remains callable
  # for controlled rollouts via the prompt_assembly feature flag.
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
    LEGACY_PROMPT_BUILDER = "legacy_prompt_builder"
    # A perf follow-up needs to see what the PR touched, not the whole diff.
    PAGE_LOAD_CHANGED_FILE_LIMIT = 50
    PROMPT_ASSEMBLY_BUILDER = "prompt_assembly"

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

    attr_reader :project, :pr_number, :github_client, :rebase_succeeded,
                :lint_command, :test_command, :issue, :prompt_version, :focus,
                :agent_run, :prompt_builder

    def initialize(project:, pr_number:, github_client:, rebase_succeeded:,
                   lint_command: nil, test_command: nil, issue: nil, prompt_version: nil,
                   focus: "general", agent_run: nil, prompt_builder: LEGACY_PROMPT_BUILDER)
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
      @prompt_builder = prompt_builder.to_s
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
    # @spec PROMPT-ASSEMBLY-007
    def self.select_trusted_comments(comments, project:)
      comments.select do |comment|
        PromptAssembly::Trust.human_trusted?(project, comment.user&.login) &&
          !paid_generated_pr_comment?(comment.body)
      end
    end

    # Delegates to the centralized trust policy so Paid-generated status
    # comments are recognized in exactly one place.
    def self.paid_generated_pr_comment?(body)
      PromptAssembly::Trust.paid_status_comment?(body)
    end
    private_class_method :paid_generated_pr_comment?

    def includes_review_threads?
      include_section?(:code_review) && review_threads_present?
    end

    # @spec LID-RUNS-004
    # Returns true when this PR was opened by a lid_planning run and has
    # unresolved review threads. The review-goal follow-up on a Planning PR
    # carries the [inferred]-correction feedback and needs a distinct prompt
    # path rather than generic code-review framing.
    def planning_pr_revision?
      return false unless includes_review_threads?

      @planning_pr_revision ||= AgentRun.planning_run_for_pr(
        project_id: project.id,
        pr_number: pr_number
      ).present?
    end

    def unresolved_review_thread_ids
      return [] unless trusted_review_threads.any?

      trusted_review_threads.filter_map { |thread| thread[:id] }
    end

    # @spec PROMPT-ASSEMBLY-018
    def review_feedback_context_blocked?
      focus == "review_feedback" &&
        human_review_threads_present? &&
        trusted_review_threads.empty?
    end

    # Returns the assembled prompt text. Existing callers (PreparePrPromptActivity,
    # scripts, and tests) continue to receive a plain string.
    def build
      return build_result.text.delete("\x00") if prompt_assembly?

      base = base_prompt_text.delete("\x00")

      with_style_guides = StyleGuides::InjectIntoPrompt.call(
        prompt: base,
        project: project,
        agent_run: agent_run,
        source: self.class.name
      )
      with_conventions = ProjectConventions::InjectIntoPrompt.call(prompt: with_style_guides, project: project)
      Lid::InjectIntoPrompt.call(prompt: with_conventions, project: project, goal: agent_run&.goal)
    end

    def prompt_assembly?
      prompt_builder == PROMPT_ASSEMBLY_BUILDER
    end

    # Returns the full assembly result: prompt text plus section provenance.
    # +sections+ records every included section (key, source, trust level,
    # inclusion reason); +skipped+ records excluded/disabled sections as
    # counts/provenance only — never bodies — so untrusted content cannot
    # leak through the result. PreparePrPromptActivity persists this
    # provenance on the agent run's prepare_pr_prompt phase metadata.
    # @spec PROMPT-ASSEMBLY-011, PROMPT-ASSEMBLY-012
    def build_result
      @build_result ||= PromptAssembly::Build.call(sections: build_sections, profile: resolved_profile)
    end

    private

    # @spec PROMPT-ASSEMBLY-016
    def base_prompt_text
      return build_result.text if prompt_assembly?

      legacy_prompt_text
    end

    # Restores the pre-assembly behavior: included sections are concatenated
    # directly, while excluded untrusted inputs remain out of the prompt.
    def legacy_prompt_text
      build_sections
        .reject { |section| legacy_injected_section?(section) }
        .reject(&:excluded?)
        .reject(&:blank?)
        .map(&:render)
        .join("\n\n")
    end

    def legacy_injected_section?(section)
      [ :style_guides, :project_conventions, :lid_workflow ].include?(section.key)
    end

    # Resolves the assembly profile from project/account/global config.
    # Falls back to the default profile when no project is available
    # (scripts, REPLs).
    # @spec PROMPT-ASSEMBLY-012
    def resolved_profile
      return PromptAssembly::Profile.default unless project

      @resolved_profile ||= PromptAssembly::ProfileResolution.resolve(
        project: project,
        account: project.account,
        goal: effective_goal
      )
    end

    # Ordered list of sections assembled into the PR follow-up prompt.
    # Each section declares its key, source, trust level, and required flag
    # so PromptAssembly::Build can produce auditable provenance and exclude
    # untrusted content without leaking bodies.
    def build_sections
      [
        task_section,
        (issue_requirements_section if include_issue_requirements_section?),
        (merge_conflicts_section if include_merge_conflicts_section?),
        (ci_failures_section if include_ci_failures_section?),
        (page_load_regression_section if include_page_load_regression_section?),
        *review_section_with_excluded,
        (planning_pr_revision_section if planning_pr_revision?),
        *conversation_section_with_excluded,
        other_issues_section,
        instructions_and_rules_shell,
        service_environment_section,
        style_guides_section,
        project_conventions_section,
        lid_workflow_section
      ].flatten.compact
    end

    def instructions_and_rules_shell
      vars = {
        priority_list: priority_list,
        setup_database_instruction: setup_database_instruction,
        review_scan_instruction: review_scan_instruction,
        already_addressed_instruction: already_addressed_instruction,
        lint_command: lint_command,
        test_command: test_command
      }

      content = if prompt_version.present?
        prompt_version.render(vars)
      else
        Prompts::Render.call(
          slug: PROMPT_SLUG,
          project: project,
          variables: vars,
          fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
        )
      end

      PromptAssembly::Section.new(
        key: :instructions_and_rules,
        source: :instructions_and_rules,
        content: content.to_s,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "core instructions and rules shell"
      )
    end

    def service_environment_section
      content = ServiceContainerSections.service_environment_section_for(
        project: project,
        include_setup_instruction: false
      )

      PromptAssembly::Section.new(
        key: :service_environment,
        source: :service_environment,
        content: content.to_s,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "service container guardrails"
      )
    end

    def style_guides_section
      PromptAssembly::Sections::StyleGuides.call(prompt_assembly_context)
    end

    def project_conventions_section
      PromptAssembly::Sections::ProjectConventions.call(prompt_assembly_context)
    end

    def lid_workflow_section
      PromptAssembly::Sections::LidWorkflow.call(prompt_assembly_context)
    end

    def prompt_assembly_context
      @prompt_assembly_context ||= PromptAssembly::Context.new(
        issue: issue,
        project: project,
        github_client: github_client,
        agent_run: agent_run
      )
    end

    def effective_goal
      agent_run&.goal || "review"
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

    def focused? # @spec FOCUSED-RUN-003
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
      content = <<~SECTION
        # Task

        You are working on an existing pull request:

        **#{pr_data.title}** (##{pr_number})

        Base branch: `#{base_branch}`

        #{pr_data.body}
      SECTION

      PromptAssembly::Section.new(
        key: :task,
        source: :pull_request,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "PR title/body/base branch"
      )
    end

    def issue_requirements_section
      content = <<~SECTION
        # Issue Requirements

        This PR is linked to the following issue:

        **#{issue.title}** (##{issue.github_number})

        #{issue.body}

        Evaluate whether the current PR changes fully implement the issue requirements.
        Close any implementation or testing gaps you find.
      SECTION

      PromptAssembly::Section.new(
        key: :issue_requirements,
        source: :issue,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "linked issue body and requirement review"
      )
    end

    def merge_conflicts_section
      content = <<~SECTION
        # Merge Conflicts

        Automatic rebase against `#{base_branch}` failed due to conflicts.
        Run `git merge origin/#{base_branch}` and resolve all conflicts.
        Ensure the merged result compiles and passes all tests.
      SECTION

      PromptAssembly::Section.new(
        key: :merge_conflicts,
        source: :merge_conflicts,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "rebase against #{base_branch} failed"
      )
    end

    def ci_failures_section
      names = ci_failure_context.checks.map { |c| "- #{c[:name]} (#{c[:conclusion]})" }.join("\n")
      output = ci_failure_context.output

      content = <<~SECTION
        # CI Status: FAILING

        The following CI checks are failing on this branch:

        #{names}

        #{ci_failure_output_section(output)}

        #{ci_failure_guidance_section}

        Fix the issue causing these CI failures. Do not skip or disable checks.
      SECTION

      PromptAssembly::Section.new(
        key: :ci_failures,
        source: :ci_failures,
        content: content,
        trust_level: :quarantined,
        required: true,
        inclusion_reason: "failing CI checks present on branch"
      )
    end

    # Built from the regression evidence persisted on the run at queue time, so
    # the prompt describes one stable measurement rather than re-measuring.
    #
    # Route names and paths come from the repository's screenshot config and the
    # file list from the pull request's diff, so the section is quarantined like
    # any other repository-derived context (PROMPT-ASSEMBLY-003) even though the
    # measurement around it is Paid's own.
    # @spec FOCUSED-RUN-003
    def page_load_regression_section
      evidence = page_load_regression_evidence
      spread = evidence["sample_spread"].to_h
      changed = Array(evidence["changed_files"])
      files = changed.first(PAGE_LOAD_CHANGED_FILE_LIMIT).map { |file| "- #{file}" }.join("\n")
      if changed.size > PAGE_LOAD_CHANGED_FILE_LIMIT
        files += "\n- …and #{changed.size - PAGE_LOAD_CHANGED_FILE_LIMIT} more"
      end

      content = <<~SECTION
        # Page Load Regression

        This PR made `#{evidence["route_name"]}` (#{evidence["route_path"]}) measurably slower.

        - Metric: #{evidence["comparison_metric"]}
        - Before (#{evidence["baseline_commit_sha"]}): #{evidence["baseline_ms"]} ms
        - After (#{evidence["commit_sha"]}): #{evidence["current_ms"]} ms
        - Slower by: #{evidence["delta_ms"]} ms
        - Sample spread: #{spread.to_json}

        Files this PR changed:

        #{files.presence || "- (not recorded)"}

        Find what in this PR's changes made the page slower and fix it. Do not
        remove the page's functionality or weaken tests to reclaim the time. If
        the cost is unavoidable, say so in a PR comment instead of guessing.
      SECTION

      PromptAssembly::Section.new(
        key: :page_load_regression,
        source: :page_load_regression,
        content: content,
        trust_level: :quarantined,
        required: true,
        inclusion_reason: "page load regression measured on a route this PR touched"
      )
    end

    def include_page_load_regression_section?
      include_section?(:page_load_regression) && page_load_regression_evidence.present?
    end

    def page_load_regression_evidence
      metadata = @agent_run&.external_metadata
      return {} unless metadata.is_a?(Hash)

      metadata["page_load_regression"].to_h
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

    # Returns the included code-review section plus excluded inputs as
    # separate sections so the assembler records untrusted thread comments
    # as provenance without leaking their bodies. When every thread is
    # untrusted, the included section is omitted but the excluded inputs
    # are still recorded so the audit trail captures who tried to inject.
    def review_section_with_excluded
      excluded = excluded_review_thread_inputs
      return [] if excluded.empty? && !includes_review_threads?

      sections = []
      sections << code_review_section if includes_review_threads?
      sections.concat(excluded.map(&:to_section))
      sections
    end

    # Code review threads filtered to trusted authors. Each comment is
    # classified via PromptAssembly::Trust and excluded comments are
    # captured as excluded sections so the assembler records them as
    # counts/provenance only.
    def code_review_section
      threads = trusted_review_threads

      thread_text = threads.map do |thread|
        comments = thread[:comments].map do |c|
          location = [ c[:path], c[:line] ].compact.join(":")
          "  - **#{c[:author]}**#{" (#{location})" if location.present?}: #{c[:body]}"
        end.join("\n")

        "**Thread** (#{thread[:comments].first&.dig(:path) || "general"}):\n#{comments}"
      end.join("\n\n")

      content = <<~SECTION
        # Code Review Comments

        The following review threads are unresolved:

        #{thread_text}

        Address each thread: fix the code if the reviewer is correct, or explain
        your reasoning in a code comment if you disagree. Do not ignore review feedback.
      SECTION

      PromptAssembly::Section.new(
        key: :code_review,
        source: :review_thread,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "unresolved review threads present"
      )
    end

    # @spec LID-RUNS-004
    # Reframes the review feedback as intent corrections for a Planning PR.
    # The review threads above (shown by code_review_section) target [inferred]
    # decision markers in the LID design artifacts — the agent must revise the
    # LLD/EARS content and replace the markers with authored rationale, not
    # treat the feedback as code fixes.
    def planning_pr_revision_section
      content = <<~SECTION
        # Planning PR Intent Correction

        This pull request is a LID Planning PR containing docs-only design
        artifacts. The review comments above target `[inferred]` decision markers
        in the LID design tree. Treat each review comment as a correction to the
        design intent, not a code-fix request.

        For each unresolved review thread targeting an `[inferred]` marker:
        1. Locate the marker in the LLD or EARS file under `docs/intent/`.
        2. Revise the affected LLD/EARS content to incorporate the reviewer's
           correction.
        3. Replace the `[inferred]` marker with the reviewer's authored rationale.
        4. Keep changes docs-only — edit only files under `docs/` and the
           instruction file (`AGENTS.md`/`CLAUDE.md`). Do not modify code.

        The `[inferred]` markers sit inline in the diff. The review comments ARE
        the corrections — apply them directly to the LID artifacts.
      SECTION

      PromptAssembly::Section.new(
        key: :planning_pr_revision,
        source: :planning_pr_revision,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "LID Planning PR with unresolved review threads"
      )
    end

    # Returns the included conversation section plus excluded inputs as
    # separate sections so the assembler records untrusted collaborator
    # comments as provenance without leaking their bodies. When every
    # comment is untrusted, the included section is omitted but the
    # excluded inputs are still recorded so the audit trail captures
    # who tried to inject.
    def conversation_section_with_excluded
      excluded = excluded_conversation_inputs
      return [] if excluded.empty? && !include_conversation_section?

      sections = []
      sections << conversation_section if include_conversation_section?
      sections.concat(excluded.map(&:to_section))
      sections
    end

    def conversation_section
      trusted = trusted_conversation_comments

      comment_text = trusted.map do |c|
        "- **#{c.user.login}**: #{truncate_comment_body(c.body.to_s)}"
      end.join("\n")

      content = <<~SECTION
        # Conversation Comments

        Recent comments from project collaborators:

        #{comment_text}

        Address any actionable requests in these comments.
      SECTION

      PromptAssembly::Section.new(
        key: :conversation,
        source: :conversation,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "trusted collaborator comments present"
      )
    end

    def other_issues_section
      return nil unless focused?

      issues = deferred_issue_descriptions
      return nil if issues.empty?

      content = <<~SECTION
        # Other Issues on This PR (Deferred)

        This PR also has the following issues that are **not** your responsibility this run:
        #{issues.map { |issue| "- #{issue}" }.join("\n")}

        Ignore the "fix forward" directive for these unrelated problems. Follow-up runs will address them.
        Do not attempt to fix these issues. Focus solely on the task described above.
      SECTION

      PromptAssembly::Section.new(
        key: :other_issues,
        source: :other_issues,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: "focused run with deferred work classes"
      )
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

    def include_section?(section) # @spec FOCUSED-RUN-003
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
        "performance_regression" => :page_load_regression,
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
      trusted_review_threads.any?
    end

    def conversation_comments_present?
      trusted_conversation_comments.any?
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
        "performance_regression" => include_page_load_regression_section?,
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
        "performance_regression" => "Fix the page load regression this PR introduced",
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

    def human_review_threads_present?
      unresolved_threads.any? do |thread|
        thread[:comments].any? { |comment| human_review_comment?(comment) }
      end
    end

    # Human context excludes every bot author: Paid's own bot, GitHub App
    # bots (logins ending in "[bot]"), and runner bots posting under bare
    # aliases. Unlisted review bots must not be misread as human, or
    # review-feedback runs would block on bot-authored threads even though
    # their comments are excluded from prompt instructions.
    def human_review_comment?(comment)
      login = comment[:author].to_s.downcase
      login.present? &&
        !project.paid_bot_author?(login) &&
        !RunnerSupport.github_bot_username?(login)
    end

    # Filters unresolved review threads to only include comments authored by
    # allowlisted collaborators or enabled review bots. GitHub's review-thread
    # API can report app authors without "[bot]", so the review-thread path
    # admits the configured bot-login set without broadening comment trust.
    # @spec FOCUSED-RUN-009
    def trusted_review_threads
      threads = unresolved_threads.filter_map do |thread|
        kept_comments = thread[:comments].select do |comment|
          trusted_review_thread_author?(comment[:author])
        end
        next nil if kept_comments.empty?

        thread.merge(comments: kept_comments)
      end

      threads
    end

    # Per-comment TrustedInputs for comments authored by non-allowlisted
    # collaborators. These become excluded sections during assembly so
    # they appear as provenance only.
    def excluded_review_thread_inputs
      unresolved_threads.flat_map do |thread|
        thread[:comments].filter_map do |comment|
          next if trusted_review_thread_author?(comment[:author])

          PromptAssembly::TrustedInput.new(
            kind: :review,
            source: :review_thread,
            login: comment[:author],
            body: nil,
            trust: :excluded,
            exclusion_reason: comment[:author].present? ? "author_not_in_allowlist" : "missing_author_identity"
          )
        end
      end
    end

    def trusted_review_thread_author?(login)
      PromptAssembly::Trust.review_thread_author_trusted?(project, login)
    end

    def trusted_comments
      @trusted_comments ||= begin
        trusted_conversation_comments
      rescue GithubClient::Error
        []
      end
    end

    # Single shared fetch for conversation comments: trusts the comments
    # back to a sufficient limit and captures excluded comments as
    # TrustedInput objects for provenance. Both #trusted_conversation_comments
    # and #excluded_conversation_inputs read from this memoized result so
    # the GitHub fetch happens exactly once per build.
    def classified_conversation_comments_with_backfill
      @classified_conversation_comments_with_backfill ||= begin
        classified = classified_conversation_comments
        pages_fetched = recent_comment_page_window

        while classified[:trusted].size < max_prompt_comments && pages_fetched < MAX_RECENT_COMMENT_PAGES
          break unless classified[:page_state]&.respond_to?(:next_older_page_url) && classified[:page_state].next_older_page_url

          older_page = github_client.fetch_issue_comment_page(classified[:page_state].next_older_page_url)
          classified = merge_classified_page(
            classified,
            fetch_and_classify(older_page)
          )
          pages_fetched += 1
        end

        classified
      rescue GithubClient::Error
        { trusted: [], excluded: [], page_state: nil }
      end
    end

    def trusted_conversation_comments
      classified_conversation_comments_with_backfill[:trusted].last(max_prompt_comments)
    end

    # Tracks the excluded comments observed during backfill so the
    # assembler can record their provenance without leaking bodies.
    def excluded_conversation_inputs
      classified_conversation_comments_with_backfill[:excluded]
    end

    def classified_conversation_comments
      page = github_client.recent_issue_comments(
        project.full_name,
        pr_number,
        pages: recent_comment_page_window
      )
      fetch_and_classify(page)
    end

    def fetch_and_classify(page)
      classified = { trusted: [], excluded: [], page_state: page }

      Array(page).each do |comment|
        input = PromptAssembly::Trust.classify_comment(project, comment, source: :conversation)
        if input.trusted?
          classified[:trusted] << comment
        else
          classified[:excluded] << input
        end
      end

      classified
    end

    def merge_classified_page(accumulated, new_page)
      {
        trusted: accumulated[:trusted] + new_page[:trusted],
        excluded: accumulated[:excluded] + new_page[:excluded],
        page_state: new_page[:page_state]
      }
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

    def select_trusted_comments(comments)
      self.class.select_trusted_comments(comments, project: project)
    end

    def truncate_comment_body(body)
      return body if body.length <= max_comment_length

      "#{body[0, max_comment_length]}… [truncated]"
    end

    # Primary detected language, used for DB-aware setup guidance by the
    # ServiceContainerSections concern. Test/lint command resolution is
    # polyglot-aware via LanguageCommands below.
    def detected_language
      @detected_language ||= LanguageCommands.detected_language(project)
    end

    def detected_lint_command
      LanguageCommands.format_for_prompt(LanguageCommands.lint_commands_for(project))
    end

    def detected_test_command
      LanguageCommands.format_for_prompt(LanguageCommands.test_commands_for(project))
    end
  end
end
