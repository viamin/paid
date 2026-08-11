# frozen_string_literal: true

require "open3"

module Activities
  class CreatePullRequestActivity < BaseActivity
    activity_name "CreatePullRequest"

    LID_REPORT_HEADING = "## LID Phase Report"
    SPEC_TAG = "@ spec".delete(" ")
    SPEC_ID_PATTERN = /([A-Z0-9-]+-\d+)/

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      return completion_result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run_id, phase_key: "create_pull_request", phase_group: "post", agent_run: agent_run) do
        project = agent_run.project
        issue = agent_run.issue

        client = project.client

        # Pre-run guard: verify the branch exists on GitHub and check for
        # an existing open PR. This eliminates orphan branches (#1125) by
        # ensuring a PR is always created when the branch is present.
        branch_exists = branch_exists?(client, project, agent_run.branch_name, agent_run_id: agent_run_id)
        existing_pr = find_existing_pr(client, project, agent_run.branch_name, agent_run_id: agent_run_id)

        # LID planning runs are docs-only: verify the changed files
        # before creating or reusing the PR. If the agent edited code
        # outside of docs/ or the instruction file, fail the run instead
        # of publishing a misleading "Planning PR". This check runs
        # regardless of whether the PR is new or already exists, so a
        # retry that finds an open PR cannot bypass it.
        if agent_run.lid_planning_goal?
          # Fetch changed files once and thread the result into both checks
          # (allowlist then output contract) to avoid a redundant GitHub
          # compare request on every lid_planning PR creation.
          changed_files = validate_lid_planning_changed_files!(agent_run, client)
          enforce_lid_planning_contract!(agent_run, changed_files: changed_files)
        end

        # create_feature runs are docs-only (RDR markdown under docs/rdrs/):
        # verify the changed files and enforce the RDR output contract
        # before opening the PR. Mirrors the lid_planning guard.
        # @spec CREATE-FEATURE-003
        if agent_run.create_feature_goal?
          changed_files = validate_create_feature_changed_files!(agent_run, client)
          enforce_create_feature_contract!(agent_run, changed_files: changed_files, client: client)
        end

        if existing_pr
          pr = existing_pr
          pr_action = "reused"
        elsif branch_exists
          pr_body = build_pr_body(issue, agent_run, client: client)
          pr, pr_action = create_pull_request_or_reuse(
            client, project, agent_run, issue, pr_body, agent_run_id: agent_run_id
          )
        else
          # Branch confirmed missing (404). Raise so Temporal retries —
          # the branch may appear after a push that is still in flight.
          raise "Branch #{agent_run.branch_name} does not exist on GitHub"
        end

        # Persist completion as the very first step after obtaining the PR,
        # before any best-effort post-processing. This ensures a retry
        # cannot overwrite status via MarkAgentRunFailedActivity.
        completed = agent_run.complete!(
          result_commit: agent_run.result_commit_sha,
          pr_url: pr.html_url,
          pr_number: pr.number
        )
        reconcile_pull_request(
          agent_run,
          client,
          project,
          pr,
          pr_action,
          issue: issue,
          llm_generated_description: pr_body&.fetch(:llm_generated_description, false)
        )

        unless completed
          logger.info(
            message: "agent_execution.pull_request_completion_skipped",
            agent_run_id: agent_run_id,
            status: agent_run.reload.status,
            pull_request_url: pr.html_url
          )
        end

        { agent_run_id: agent_run_id, pull_request_url: pr.html_url, pull_request_number: pr.number }
      end
    end

    private

    def completion_result(agent_run)
      {
        agent_run_id: agent_run.id,
        pull_request_url: agent_run.pull_request_url,
        pull_request_number: agent_run.pull_request_number,
        skipped: agent_run.pull_request_url.blank?,
        cancelled: agent_run.status == "cancelled"
      }
    end

    # Checks whether the branch exists on GitHub via the refs API.
    # Returns true when confirmed or when the check fails transiently
    # (optimistic — lets the caller attempt PR creation so GitHub is
    # the source of truth). Returns false only on a confirmed 404.
    def branch_exists?(client, project, branch_name, agent_run_id:)
      client.ref(project.full_name, "heads/#{branch_name}")
      true
    rescue GithubClient::NotFoundError
      logger.info(
        message: "agent_execution.branch_not_found",
        agent_run_id: agent_run_id,
        branch: branch_name
      )
      false
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.branch_check_failed",
        agent_run_id: agent_run_id,
        branch: branch_name,
        error: e.message
      )
      true
    end

    def find_existing_pr(client, project, branch_name, agent_run_id:)
      existing = client.pull_requests(
        project.full_name,
        head: "#{project.owner}:#{branch_name}",
        state: "open"
      )
      existing.first
    rescue StandardError => e
      # Lookup is best-effort: a transient failure (including network-level
      # errors like Faraday::TimeoutError) must not become a new failure
      # mode introduced by the idempotency fix. Fall through to
      # create_pull_request and let GitHub be the source of truth.
      logger.warn(
        message: "agent_execution.pull_request_lookup_failed",
        agent_run_id: agent_run_id,
        branch: branch_name,
        error: e.message
      )
      nil
    end

    # Creates the PR, but treats a GitHub 422 "pull request already exists"
    # response as a reuse signal: a prior attempt (or a transient lookup
    # failure that masked an existing PR) already created the PR, so we
    # re-query and reuse it instead of letting the 422 retry pointlessly.
    # Returns a [pr, action] tuple where action is "created" or "reused".
    def create_pull_request_or_reuse(client, project, agent_run, issue, pr_body, agent_run_id:)
      pr = client.create_pull_request(
        project.full_name,
        base: project.default_branch,
        head: agent_run.branch_name,
        title: pr_title(agent_run, issue),
        body: pr_body.fetch(:body),
        draft: true
      )
      [ pr, "created" ]
    rescue GithubClient::ApiError => e
      raise e unless pr_already_exists_error?(e)

      logger.info(
        message: "agent_execution.pull_request_create_conflict_reuse",
        agent_run_id: agent_run_id,
        branch: agent_run.branch_name,
        error: e.message
      )
      reused = find_existing_pr(client, project, agent_run.branch_name, agent_run_id: agent_run_id)
      raise e if reused.nil?

      [ reused, "reused" ]
    end

    def pr_already_exists_error?(error)
      return false unless error.respond_to?(:status) && error.status == 422

      error.message.to_s.match?(/a pull request already exists|pull request.*already exist/i)
    end

    def best_effort(agent_run_id, context: nil)
      yield
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.post_processing_failed",
        agent_run_id: agent_run_id,
        context: context,
        error_class: e.class.name,
        error: e.message
      )
    end

    def reconcile_pull_request(agent_run, client, project, pr, pr_action, issue:, llm_generated_description: false)
      agent_run_id = agent_run.id

      # Best-effort post-processing runs even when cancellation wins the
      # complete! lock, because the GitHub PR already exists at this point.
      best_effort(agent_run_id, context: "sync_created_pull_request") { sync_pull_request_record(client, project, pr.number) }
      best_effort(agent_run_id, context: "add_pr_labels") { add_pr_labels(client, project, pr.number, agent_run_id, issue: issue) }
      best_effort(agent_run_id, context: "log_pr_action") { agent_run.log!("system", "PR #{pr_action}: #{pr.html_url}") }

      best_effort(agent_run_id, context: "structured_log") do
        logger.info(
          message: "agent_execution.pull_request_#{pr_action}",
          agent_run_id: agent_run_id,
          pull_request_url: pr.html_url
        )
      end

      if llm_generated_description
        best_effort(agent_run_id, context: "record_pr_description_metric") do
          record_pr_description_metric(project, pr.number, original_text: pr.body)
        end
      end
    end

    def pr_title(agent_run, issue)
      return "docs: bootstrap LID design tree" if agent_run.lid_planning_goal?
      return create_feature_pr_title(agent_run) if agent_run.create_feature_goal?
      return fallback_custom_prompt_title(agent_run) || "Agent changes" unless issue

      ConventionalCommitTitle.for_issue(issue, project: issue.project, style_key: "pr_title_style").truncate(255)
    end

    def build_pr_body(issue, agent_run, client: nil)
      return build_lid_planning_pr_body(agent_run) if agent_run.lid_planning_goal?
      return build_create_feature_pr_body(agent_run) if agent_run.create_feature_goal?

      summary = agent_run.agent_summary
      validate_summary_scope(summary, issue, agent_run, client: client)
      description = generate_description(summary, issue, agent_run_id: agent_run.id)
      quality_warnings = quality_warning_section(agent_run)
      lid_coherence = lid_coherence_section(agent_run)

      template = resolve_pr_template(agent_run)
      body = if template
        rendered = render_pr_template(template, issue, agent_run, description, quality_warnings)
        append_coherence_section(rendered, lid_coherence)
      else
        build_default_pr_body(issue, agent_run, description, quality_warnings: quality_warnings, lid_coherence: lid_coherence)
      end

      {
        body: append_lid_phase_report(body, agent_run),
        llm_generated_description: description.present?
      }
    end

    def build_default_pr_body(issue, agent_run, description, quality_warnings: nil, lid_coherence: nil)
      parts = []

      if description.present?
        parts << description
      else
        parts << fallback_body(issue, agent_run)
      end

      if quality_warnings.present?
        parts << ""
        parts << quality_warnings
      end

      if lid_coherence.present?
        parts << ""
        parts << lid_coherence
      end

      parts << ""

      if issue
        parts << "---"
        parts << ""
        parts << "Closes ##{issue.github_number}"
      end

      parts.join("\n")
    end

    # Builds a goal-specific PR body for lid_planning runs.
    # Uses the agent summary (which contains the planning analysis)
    # and appends a review checklist for the project owner to verify
    # the inferred LID decisions.
    def build_lid_planning_pr_body(agent_run)
      summary = agent_run.agent_summary
      description = if summary.present?
        generate_description(summary, nil, agent_run_id: agent_run.id) || summary
      end

      body = if description.present?
        description
      else
        [
          "## Summary",
          "",
          "This Planning PR bootstraps the LID design tree from brownfield analysis.",
          ""
        ].join("\n")
      end

      # The LID Planning prompt requires a "Confirm these inferred decisions"
      # checklist in the PR description. generate_description may collapse it
      # from the raw agent summary, so extract it separately and append it
      # when it is missing from the final body.
      checklist = extract_lid_planning_checklist(summary)
      if checklist.present? && !body.include?("Confirm these inferred decisions")
        body = "#{body}\n\n#{checklist}"
      end

      {
        body: body,
        llm_generated_description: false
      }
    end

    # Extracts the "Confirm these inferred decisions" checklist from the raw
    # agent summary. The LID Planning prompt instructs the agent to format
    # each item as a Markdown checkbox with the segment and decision text.
    #
    # Returns the full section (heading + items) as a string, or nil when
    # no checklist can be found.
    def extract_lid_planning_checklist(summary)
      return nil if summary.blank?

      # Match a heading like "## Confirm these inferred decisions" and
      # capture its content through the next same-or-higher-level heading.
      section = summary.match(
        /^\#{1,4}\s*Confirm these inferred decisions\s*$(.+?)(?=^\#{1,4}\s|\z)/mi
      )
      return section[0].strip if section

      # Fallback: the agent may have included checkbox items without an
      # explicit heading. Look for a block of consecutive checkbox lines
      # and wrap them in the expected heading.
      checkbox_block = summary.match(
        /(?:^[-*]\s*\[[ x]\]\s*.+$\n?){1,}/m
      )
      return nil unless checkbox_block

      "## Confirm these inferred decisions\n\n#{checkbox_block[0].strip}"
    end

    def resolve_pr_template(agent_run)
      PrTemplate.resolve(
        project: agent_run.project,
        user: agent_run.settings_user
      )
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.pr_template_resolve_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def render_pr_template(template, issue, agent_run, description, quality_warnings)
      variables = {
        "description" => description.presence || fallback_description(issue, agent_run),
        "agent_summary" => agent_run.agent_summary.presence || "",
        "branch_name" => agent_run.branch_name.to_s,
        "issue_number" => issue&.github_number.to_s,
        "issue_title" => issue&.title.to_s,
        "issue_url" => issue ? "##{issue.github_number}" : "",
        "quality_warnings" => quality_warnings.to_s
      }
      template.render(variables)
    end

    # The coherence soft-block must appear on the PR body regardless of
    # whether the selected template renders {{quality_warnings}} (#3083).
    # Templates that omit that placeholder would otherwise silently drop
    # the coherence section.
    def append_coherence_section(body, lid_coherence)
      return body if lid_coherence.blank?

      "#{body}\n\n#{lid_coherence}"
    end

    def quality_warning_section(agent_run)
      warnings = agent_run.agent_run_logs.system.filter_map do |log|
        metadata = log.metadata || {}
        next unless metadata["event"] == "pre_commit_check"
        next unless metadata["passed"] == false
        next unless metadata["failure_behavior"] == "warn"

        output = quality_warning_output(metadata)
        next if output.blank?

        "- #{output}".strip
      end.uniq
      return if warnings.empty?

      [
        "## Quality Warnings",
        "",
        *warnings
      ].join("\n")
    end

    def quality_warning_output(metadata)
      feedback_errors = Array(metadata.dig("quality_feedback", "errors"))
      return feedback_errors.map { |error| error["message"] || error[:message] }.compact.join("; ") if feedback_errors.any?

      metadata["output_preview"].to_s
    end

    def lid_coherence_section(agent_run)
      Lid::CoherenceSection.render(
        agent_run,
        closing_note: "This run continued intentionally; the checker is advisory, not a hard gate."
      )
    end

    # Deterministic fallback used when the LLM description generator fails or
    # returns nothing. Never uses raw agent stdout — that output may contain
    # debugging commentary, error-chasing notes, or other non-summary text
    # that is unsuitable as a PR description (see PR #2859).
    def fallback_body(issue, agent_run = nil)
      [ "## Summary", "", fallback_description(issue, agent_run) ].join("\n")
    end

    # @spec CHAT-PR-PROPOSAL-006
    def fallback_custom_prompt_title(agent_run)
      prompt = agent_run.custom_prompt.to_s
      explicit_title = prompt[/\b(?:PR|pull request)\s+titled\s+[`"“]([^`"”\n]+)[`"”]/i, 1] ||
        prompt[/\b(?:PR|pull request)\s+titled\s+(.+?)(?:\s+with\b|[.!?]\s*$|\n|$)/i, 1]
      (redact_for_pr_metadata(explicit_title).presence || custom_prompt_excerpt(prompt))
        .to_s.strip.delete_suffix(".").truncate(255).presence
    end

    def fallback_description(issue, agent_run)
      if issue
        [ issue.title, "", "See ##{issue.github_number} for context." ].join("\n")
      elsif agent_run&.custom_prompt.present?
        custom_prompt_excerpt(agent_run.custom_prompt)
      else
        "This pull request was automatically generated by [Paid](https://github.com/viamin/paid)."
      end
    end

    def custom_prompt_excerpt(prompt)
      excerpt = redact_for_pr_metadata(prompt.to_s.lines.map(&:strip).find(&:present?))
      neutralize_inline_markdown(excerpt).truncate(1_000).presence
    end

    # Prevents prompt content from rendering as active GitHub markdown
    # (tracking images ![alt](url), phishing/[links](url)) when published as
    # a PR body. Targeted at link/image syntax so ordinary prose is unaffected.
    def neutralize_inline_markdown(text)
      text.to_s
        .gsub("![", "! [")
        .gsub("](", "] (")
    end

    def redact_for_pr_metadata(text)
      Knowledge::Redaction::Redactor.call(text: text).clean_text
    end

    def generate_description(summary, issue, agent_run_id:)
      return nil if summary.blank?

      description = Llm::GeneratePrDescription.call(
        agent_summary: summary,
        issue_title: issue&.title,
        issue_body: issue&.body
      )

      if description.nil?
        logger.warn(
          message: "agent_execution.pr_description_llm_unsuccessful",
          agent_run_id: agent_run_id,
          issue_number: issue&.github_number,
          summary_length: summary.length
        )
      end

      description
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.pr_description_failed",
        agent_run_id: agent_run_id,
        issue_number: issue&.github_number,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def append_lid_phase_report(body, agent_run)
      return body unless lid_mode_for(agent_run.project).present?
      return body if body.include?(LID_REPORT_HEADING)

      [ body.rstrip, "", lid_phase_report(agent_run) ].join("\n")
    end

    def lid_phase_report(agent_run)
      [
        LID_REPORT_HEADING,
        "",
        "- Mode: `#{lid_mode_for(agent_run.project)}`",
        "- Specs touched: #{specs_touched_summary(agent_run)}",
        "- Tests-first evidence: #{tests_first_summary(agent_run)}",
        "- Coherence check: #{coherence_check_summary(agent_run)}"
      ].join("\n")
    end

    def lid_mode_for(project)
      return unless project.respond_to?(:lid_mode)

      project.lid_mode.to_s.strip.downcase.presence
    end

    def specs_touched_summary(agent_run)
      spec_ids = spec_ids_for_report(agent_run)
      touched_docs = touched_spec_docs(agent_run)

      details = []
      details << "EARS IDs: #{spec_ids.join(', ')}" if spec_ids.any?
      details << "intent docs: #{touched_docs.join(', ')}" if touched_docs.any?

      details.presence&.join("; ") || "No LID spec IDs or intent doc edits were detected automatically."
    end

    def tests_first_summary(agent_run)
      changed_tests = changed_test_files(agent_run)
      spec_ids = spec_ids_for_report(agent_run)

      return "Changed test files: #{changed_tests.join(', ')}." if changed_tests.any?
      return "@spec annotations detected for #{spec_ids.join(', ')}." if spec_ids.any?

      "No test-file changes or @spec annotations were detected automatically."
    end

    def coherence_check_summary(agent_run)
      line = latest_coherence_check_line(agent_run)
      return "Not found in captured agent output." unless line
      return "Reported success in agent output." if line.match?(/pass(?:ed)?|success|0 failures/i)
      return "Reported failures in agent output; inspect the run logs." if line.match?(/fail(?:ed|ures?)?/i)

      "Referenced in agent output; inspect the run logs for the full result."
    end

    def latest_coherence_check_line(agent_run)
      coherence_log = latest_coherence_log(agent_run)
      return unless coherence_log

      coherence_log.lines.reverse_each.find do |line|
        line.match?(/coherence-check\.mjs|\/opt\/paid-lid\/bin\/coherence-check\.mjs/)
      end
    end

    def latest_coherence_log(agent_run)
      agent_run.agent_run_logs
        .where(log_type: %w[stdout stderr])
        .where("content LIKE :default_path OR content LIKE :vendored_path",
          default_path: "%coherence-check.mjs%",
          vendored_path: "%/opt/paid-lid/bin/coherence-check.mjs%")
        .order(created_at: :desc, id: :desc)
        .pick(:content)
    end

    def agent_output(agent_run)
      @agent_outputs ||= {}
      @agent_outputs[agent_run.id] ||= agent_run.agent_run_logs
        .where(log_type: %w[stdout stderr])
        .order(created_at: :desc, id: :desc)
        .limit(200)
        .pluck(:content)
        .reverse
        .join("\n")
    end

    def changed_test_files(agent_run)
      changed_files(agent_run).grep(/\A(spec|test|\.ephemeral-tests)\//)
    end

    def touched_spec_docs(agent_run)
      changed_files(agent_run).grep(%r{\Adocs/intent/.+-specs\.md\z})
    end

    def spec_ids_from_diff(agent_run)
      git_diff(agent_run).scan(spec_annotation_pattern).flatten.uniq
    end

    def spec_ids_for_report(agent_run)
      (spec_ids_from_diff(agent_run) + spec_ids_from_output(agent_run)).uniq
    end

    def spec_ids_from_output(agent_run)
      agent_output(agent_run).scan(spec_annotation_pattern).flatten.uniq
    end

    def spec_annotation_pattern
      @spec_annotation_pattern ||= Regexp.new("#{Regexp.escape(SPEC_TAG)}\\s+#{SPEC_ID_PATTERN.source}")
    end

    def changed_files(agent_run)
      @changed_files ||= {}
      @changed_files[agent_run.id] ||= git_diff_name_only(agent_run).lines.map(&:strip).reject(&:empty?)
    end

    def git_diff(agent_run)
      @git_diffs ||= {}
      @git_diffs[agent_run.id] ||= run_git_diff(agent_run, "--unified=0")
    end

    def git_diff_name_only(agent_run)
      @git_diff_names ||= {}
      @git_diff_names[agent_run.id] ||= run_git_diff(agent_run, "--name-only")
    end

    def run_git_diff(agent_run, *args)
      return "" if agent_run.worktree_path.blank? || agent_run.base_commit_sha.blank? || agent_run.result_commit_sha.blank?

      stdout, status = Open3.capture2(
        "git",
        "-C",
        agent_run.worktree_path,
        "diff",
        *args,
        agent_run.base_commit_sha,
        agent_run.result_commit_sha
      )
      status.success? ? stdout : ""
    rescue StandardError
      ""
    end

    # Checks whether the agent summary text plausibly relates to the target
    # issue.  Logs a structured warning when the summary appears to describe
    # a *different* issue — the most visible symptom of cross-run state
    # contamination (see GitHub issue #905).
    #
    # The check is deliberately lightweight (string matching, no LLM call)
    # so it never blocks PR creation.
    def validate_summary_scope(summary, issue, agent_run, client: nil)
      return if summary.blank? || issue.nil?

      issue_number = issue.github_number
      repo_full_name = agent_run.project.full_name

      # Match both bare (#123) and qualified (owner/repo#123) issue references,
      # capturing the optional qualifier so we can discard external-repo refs.
      # The \b anchor before the qualifier (or #) prevents in-token matches
      # like C#123 or abc#456 from being treated as issue references.
      issue_ref_pattern = /(?<!\w)([\w.\-]+\/[\w.\-]+)?#(\d+)\b/

      # Only count a qualified ref (owner/repo#NNN) as "own issue" when the
      # qualifier matches this project's full_name (case-insensitive, since
      # GitHub owner/repo names are case-insensitive).
      mentions_own_issue = summary.scan(issue_ref_pattern).any? { |qualifier, num|
        num.to_i == issue_number &&
          (qualifier.nil? || qualifier.downcase == repo_full_name.downcase)
      } || summary.match?(/\bissue\s+#{Regexp.escape(issue_number.to_s)}\b/i)

      # Extract issue numbers from the summary in a single pass, keeping only
      # bare refs (#NNN) and qualified refs matching this project (owner/repo#NNN).
      # External qualified refs (e.g. rails/rails#1234) are ignored to avoid
      # false mismatch warnings when the same number exists locally.
      referenced_numbers = summary.scan(issue_ref_pattern)
        .filter_map { |qualifier, num| num.to_i if qualifier.nil? || qualifier.downcase == repo_full_name.downcase }
        .to_set
      referenced_numbers.delete(issue_number)

      sibling_numbers = sibling_open_issue_numbers(
        agent_run.project,
        exclude: issue_number,
        candidates: referenced_numbers
      )
      cross_refs = referenced_numbers.intersection(sibling_numbers).to_a.sort

      if cross_refs.any?
        if mentions_own_issue
          # Summary mentions both its own issue and sibling issues. This is
          # likely a legitimate cross-reference, but we log at info level for
          # observability in case it turns out to be partial contamination.
          logger.info(
            message: "agent_execution.summary_cross_references",
            agent_run_id: agent_run.id,
            issue_number: issue_number,
            cross_referenced_issues: cross_refs
          )
        else
          logger.warn(
            message: "agent_execution.summary_scope_mismatch",
            agent_run_id: agent_run.id,
            issue_number: issue_number,
            cross_referenced_issues: cross_refs,
            summary_preview: summary.truncate(200)
          )
          agent_run.log!(
            "system",
            "Warning: agent summary may describe a different issue. " \
            "Expected references to ##{issue_number}, found references to: #{cross_refs.map { |n| "##{n}" }.join(", ")}"
          )
        end
      elsif !mentions_own_issue
        # Second sanity gate (see #905): the summary has no issue cross-refs
        # but also does not mention its own target issue. Check whether the
        # summary content overlaps with the actual diff — if not, the summary
        # likely drifted in from a previous run's scope.
        warn_unless_diff_overlap(summary, agent_run, client, issue_number)
      end
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.summary_scope_check_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    # Returns github_numbers of other open issues in the same project,
    # excluding the current issue.
    def sibling_open_issue_numbers(project, exclude:, candidates:)
      return [] if candidates.blank?

      project.issues
        .where(github_state: "open", is_pull_request: false, github_number: candidates)
        .where.not(github_number: exclude)
        .pluck(:github_number)
    end

    # Warns when the summary does not mention its target issue and has no
    # overlap with the files actually changed in this run. This catches the
    # contamination pattern from #905 where content from a previous run's
    # scope (different file/symbol names) drifts in without explicit issue
    # cross-references.
    def warn_unless_diff_overlap(summary, agent_run, client, issue_number)
      changed_files = fetch_changed_files(agent_run, client)
      return if changed_files.nil?

      # Check if any changed file's basename (e.g. "scanner.rb") or full
      # path appears in the summary — a lightweight signal that the summary
      # relates to the actual work done. Basenames shorter than 4 chars are
      # skipped to avoid false matches (e.g. "a.rb" matching any "a").
      has_overlap = changed_files.any? { |path|
        basename = File.basename(path, File.extname(path))
        (basename.length >= 4 && summary.include?(basename)) ||
          summary.include?(path)
      }

      return if has_overlap

      logger.warn(
        message: "agent_execution.summary_scope_mismatch",
        agent_run_id: agent_run.id,
        issue_number: issue_number,
        reason: "no_own_issue_ref_and_no_diff_overlap",
        summary_preview: summary.truncate(200)
      )
      agent_run.log!(
        "system",
        "Warning: agent summary may describe a different issue. " \
        "Summary does not reference ##{issue_number} and has no overlap with changed files."
      )
    end

    # Fetches file paths changed between base and result commits via the
    # GitHub compare API. Returns nil when insufficient data is available
    # (missing SHAs or client), so callers can skip the check gracefully.
    def fetch_changed_files(agent_run, client)
      return nil unless client
      return nil if agent_run.base_commit_sha.blank? || agent_run.result_commit_sha.blank?

      client.compare_changed_files(
        agent_run.project.full_name,
        agent_run.base_commit_sha,
        agent_run.result_commit_sha
      )
    end
    LID_PLANNING_ALLOWED_PATTERNS = [
      %r{\Adocs/},
      %r{\A\.github/copilot-instructions\.md\z},
      %r{\AAGENTS\.md\z},
      %r{\ACLAUDE\.md\z}
    ].freeze

    # Validates that a lid_planning run only touches docs/ and instruction
    # files. The prompt instructs the agent to produce docs-only changes,
    # but this server-side check ensures the PR never contains code edits
    # when the agent strays outside the docs boundary.
    #
    # Raises when non-conforming files are detected or when the changed
    # file list is unavailable (no client or missing commit SHAs). The
    # docs-only contract is server-side enforced; skipping validation
    # because comparison data is unavailable would defeat it.
    #
    # Returns the changed file list so the caller can reuse it for the
    # output-contract check without a second GitHub compare request.
    def validate_lid_planning_changed_files!(agent_run, client)
      changed_files = fetch_changed_files(agent_run, client)
      if changed_files.nil?
        raise "LID planning validation requires changed file data (missing client or commit SHAs)"
      end

      rejected = changed_files.reject { |path| lid_planning_allowed?(path) }
      return changed_files if rejected.empty?

      logger.error(
        message: "agent_execution.lid_planning_allowlist_violation",
        agent_run_id: agent_run.id,
        rejected_files: rejected,
        total_changed: changed_files.size
      )
      agent_run.log!(
        "system",
        "LID planning allowlist violation: #{rejected.to_sentence} " \
        "is outside docs/ and the instruction file. The run is aborted."
      )
      raise "LID planning changed files outside allowlist: #{rejected.join(', ')}"
    end

    # Enforces the positive output contract for a lid_planning run: that the
    # required LID artifact set (HLD, LLDs, EARS, and — for adoption — the
    # ## LID block + arrow index) was actually produced. This is separate from
    # the docs-only allowlist, which only rejects forbidden paths. The
    # contract is run-kind aware (adoption vs refinement).
    #
    # Raises when required artifacts are missing so a run that produces no
    # LID output cannot publish a misleading "Planning PR".
    # @spec LID-RUNS-007
    def enforce_lid_planning_contract!(agent_run, changed_files:)
      result = Lid::PlanningContract.call(agent_run: agent_run, changed_files: changed_files)
      return if result.valid?

      logger.error(
        message: "agent_execution.lid_planning_contract_violation",
        agent_run_id: agent_run.id,
        kind: result.kind,
        missing: result.missing,
        plan_doc_weighted: result.plan_doc_weighted
      )
      agent_run.log!(
        "system",
        "LID planning output contract not met (#{result.kind}): missing #{result.missing.to_sentence}. " \
        "The run is aborted."
      )
      raise "LID planning output contract violated: missing #{result.missing.join(', ')}"
    end

    def lid_planning_allowed?(path)
      LID_PLANNING_ALLOWED_PATTERNS.any? { |pattern| path.match?(pattern) }
    end

    # create_feature runs must only touch docs/rdrs/ paths.
    CREATE_FEATURE_ALLOWED_PATTERNS = [
      %r{\Adocs/rdrs/}
    ].freeze

    # Validates that a create_feature run only touches docs/rdrs/ paths.
    # @spec CREATE-FEATURE-003
    def validate_create_feature_changed_files!(agent_run, client)
      changed_files = fetch_changed_files(agent_run, client)
      if changed_files.nil?
        raise "create_feature validation requires changed file data (missing client or commit SHAs)"
      end

      rejected = changed_files.reject { |path| create_feature_allowed?(path) }
      return changed_files if rejected.empty?

      logger.error(
        message: "agent_execution.create_feature_allowlist_violation",
        agent_run_id: agent_run.id,
        rejected_files: rejected,
        total_changed: changed_files.size
      )
      agent_run.log!(
        "system",
        "create_feature allowlist violation: #{rejected.to_sentence} " \
        "is outside docs/rdrs/. The run is aborted."
      )
      raise "create_feature changed files outside allowlist: #{rejected.join(', ')}"
    end

    # Enforces the positive output contract for a create_feature run: that
    # the required RDR artifact (new RDR with all sections + README index
    # update) was actually produced. Mirrors the lid_planning contract gate.
    # @spec CREATE-FEATURE-003
    def enforce_create_feature_contract!(agent_run, changed_files:, client:)
      contents = fetch_create_feature_file_contents(agent_run, changed_files, client)
      result = Features::RdrContract.call(
        agent_run: agent_run,
        changed_files: changed_files,
        contents: contents
      )
      return if result.valid?

      logger.error(
        message: "agent_execution.create_feature_contract_violation",
        agent_run_id: agent_run.id,
        missing: result.missing
      )
      agent_run.log!(
        "system",
        "create_feature output contract not met: missing #{result.missing.to_sentence}. " \
        "The run is aborted."
      )
      raise "create_feature output contract violated: missing #{result.missing.join(', ')}"
    end

    # Fetches file contents for the RDR docs and README index so the contract
    # can check section presence and index update without a separate pass.
    def fetch_create_feature_file_contents(agent_run, changed_files, client)
      return {} unless client

      rdr_files = changed_files.select { |path| path.match?(%r{\Adocs/rdrs/}) }
      rdr_files.each_with_object({}) do |path, memo|
        memo[path] = client.file_content(agent_run.project.full_name, path: path, ref: agent_run.result_commit_sha) || ""
      rescue => e
        logger.warn(
          message: "agent_execution.create_feature_content_fetch_failed",
          agent_run_id: agent_run.id,
          path: path,
          error: e.message
        )
        memo[path] = ""
      end
    end

    def create_feature_allowed?(path)
      CREATE_FEATURE_ALLOWED_PATTERNS.any? { |pattern| path.match?(pattern) }
    end

    def create_feature_pr_title(agent_run)
      brief = agent_run.external_metadata&.dig("feature_brief") || {}
      title = brief["title"].presence || "New feature specification"
      "docs: RDR for #{title}"
    end

    def build_create_feature_pr_body(agent_run)
      brief = agent_run.external_metadata&.dig("feature_brief") || {}
      lines = [ "## Feature Creation RDR", "" ]

      if brief["title"].present?
        lines << "**Feature:** #{brief['title']}"
        lines << ""
      end

      lines << "This PR adds a new RDR (Recommendation Decision Record) specifying the proposed feature, "
      lines << "decomposed into a linked issue tree."
      lines << ""

      if brief["problem"].present?
        lines << "**Problem:** #{brief['problem']}"
        lines << ""
      end

      lines << "Review the RDR document under `docs/rdrs/` for the full specification."

      { body: lines.join("\n"), llm_generated_description: false }
    end


    def inherited_priority_labels(project, issue)
      return [] unless project.inherit_priority_labels?
      return [] if issue.blank? || issue.labels.blank?

      project.priority_label_names & Array(issue.labels)
    end

    def add_pr_labels(client, project, pr_number, agent_run_id, issue: nil)
      labels = []
      if project.auto_add_labels_enabled?
        labels << project.generated_label_name
        labels << project.automation_label_name
      end
      labels.concat(inherited_priority_labels(project, issue))
      labels.uniq!
      return if labels.empty?

      client.add_labels_to_issue(project.full_name, pr_number, labels)
      merge_local_pr_labels(project, pr_number, labels)
    end

    def sync_pull_request_record(client, project, pr_number)
      github_issue = client.issue(project.full_name, pr_number)
      Issues::UpsertFromGithub.call(project: project, github_issue: github_issue)
    rescue => e
      logger.warn(
        message: "agent_execution.sync_created_pull_request_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def merge_local_pr_labels(project, pr_number, labels)
      pull_request = project.issues.find_by(github_number: pr_number, is_pull_request: true)
      return unless pull_request

      pull_request.with_lock do
        pull_request.update!(labels: (pull_request.labels + labels).uniq)
      end
    end

    def record_pr_description_metric(project, pr_number, original_text: nil)
      LlmOutputMetrics::Record.call(
        project: project,
        output_type: "pr_description",
        prompt_slug: Llm::GeneratePrDescription::PROMPT_SLUG,
        source_type: "PullRequest",
        source_id: pr_number,
        metadata: { "original_text" => original_text }
      )
    end
  end
end
