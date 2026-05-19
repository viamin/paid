# frozen_string_literal: true

module Activities
  class CreatePullRequestActivity < BaseActivity
    activity_name "CreatePullRequest"

    MAX_FALLBACK_SUMMARY_LENGTH = 10_000

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      return completion_result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run_id, phase_key: "create_pull_request", phase_group: "post", agent_run: agent_run) do
        project = agent_run.project
        issue = agent_run.issue

        client = project.github_token.client

        # Pre-run guard: verify the branch exists on GitHub and check for
        # an existing open PR. This eliminates orphan branches (#1125) by
        # ensuring a PR is always created when the branch is present.
        branch_exists = branch_exists?(client, project, agent_run.branch_name, agent_run_id: agent_run_id)
        existing_pr = find_existing_pr(client, project, agent_run.branch_name, agent_run_id: agent_run_id)

        if existing_pr
          pr = existing_pr
          pr_action = "reused"
        elsif branch_exists
          pr_body = build_pr_body(issue, agent_run, client: client)
          pr = client.create_pull_request(
            project.full_name,
            base: project.default_branch,
            head: agent_run.branch_name,
            title: pr_title(issue),
            body: pr_body.fetch(:body),
            draft: true
          )
          pr_action = "created"
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

    def pr_title(issue)
      return "Agent changes" unless issue

      ConventionalCommitTitle.for_issue(issue).truncate(255)
    end

    def build_pr_body(issue, agent_run, client: nil)
      summary = agent_run.agent_summary
      validate_summary_scope(summary, issue, agent_run, client: client)
      description = generate_description(summary, issue, agent_run_id: agent_run.id)

      template = resolve_pr_template(agent_run)
      body = if template
        render_pr_template(template, issue, agent_run, description)
      else
        build_default_pr_body(issue, description, summary: summary)
      end

      {
        body: body,
        llm_generated_description: description.present?
      }
    end

    def build_default_pr_body(issue, description, summary: nil)
      parts = []

      if description.present?
        parts << description
      else
        parts << fallback_body(issue, summary: summary)
      end

      parts << ""

      if issue
        parts << "---"
        parts << ""
        parts << "Closes ##{issue.github_number}"
      end

      parts.join("\n")
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

    def render_pr_template(template, issue, agent_run, description)
      variables = {
        "description" => description.presence || "",
        "agent_summary" => agent_run.agent_summary.presence || "",
        "branch_name" => agent_run.branch_name.to_s,
        "issue_number" => issue&.github_number.to_s,
        "issue_title" => issue&.title.to_s,
        "issue_url" => issue ? "##{issue.github_number}" : ""
      }
      template.render(variables)
    end

    def fallback_body(issue, summary: nil)
      parts = []
      parts << "## Summary"
      parts << ""

      if suitable_fallback_summary?(summary)
        parts << summary.truncate(MAX_FALLBACK_SUMMARY_LENGTH, omission: "\n\n[truncated]")
      elsif issue
        parts << issue.title
        parts << ""
        parts << "See ##{issue.github_number} for context."
      else
        parts << "This pull request was automatically generated by [Paid](https://github.com/viamin/paid)."
      end

      parts.join("\n")
    end

    def suitable_fallback_summary?(text)
      return false if text.blank?
      return false if text.start_with?("{", "[")
      return false if text.start_with?("Agent encountered an error:")

      true
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
