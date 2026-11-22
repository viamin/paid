# frozen_string_literal: true

require "timeout"

module Activities
  # Completes an agent run that pushed to an existing PR's branch.
  # Marks the run as completed with the existing PR's URL/number
  # and adds a comment to the PR noting the agent pushed updates.
  # When the project has quiet_mode enabled (#4232), the per-push summary
  # comment is suppressed — the agent's commit message is the only
  # commentary channel.
  class CompleteExistingPrRunActivity < BaseActivity
    activity_name "CompleteExistingPrRun"
    COMMENT_MARKER = "<!-- paid:agent-update -->"
    SUMMARY_PREFIX = "## Agent Update"
    GENERIC_MESSAGE = "Agent pushed updates to this PR."
    SUMMARY_COMMENT_MODE = "summary"
    CONFLICT_REPAIR_SCOPE_ASSESSMENT_KEY = "conflict_repair_scope_assessment"
    # One finite enclosing deadline: the semantic scope assessment and the
    # bookkeeping around it draw their budgets from the activity's actual
    # start-to-close deadline, minus a deliberate reserve for PR publication
    # and a final reserve so the typed review stop itself always fits (#5310).
    # @spec AUTO-MERGE-011
    PUBLICATION_RESERVE_SECONDS = 15
    STOP_RESERVE_SECONDS = 5
    MINIMUM_REQUEST_SECONDS = 1
    DEFAULT_ACTIVITY_DEADLINE_SECONDS = 60

    # Raised only by the bounded stop-path publication wrapper so the typed
    # ConflictRepairScopeRejected stop survives slow or hung publication.
    class RejectionPublicationDeadlineExceeded < StandardError; end

    # Raised only when a bounded comparison read exceeds its request budget,
    # so a slow or hung GitHub compare can neither consume the enclosing
    # deadline nor displace the fail-closed assessment path.
    # @spec AUTO-MERGE-011
    class ComparisonDeadlineExceeded < StandardError; end

    class << self
      def agent_update_comment?(body)
        normalized = body.to_s

        # Prefer the explicit HTML marker when present.
        return true if normalized.include?(COMMENT_MARKER)

        # Legacy detection: treat as agent update only when the trimmed body
        # clearly matches the legacy formats, rather than any substring match.
        stripped = normalized.strip

        return true if stripped.start_with?(SUMMARY_PREFIX)
        return true if stripped == GENERIC_MESSAGE

        false
      end
    end

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      return result(agent_run) if agent_run.finished?

      @phase_metadata = {}
      @activity_deadline = activity_deadline
      track_phase(agent_run_id: agent_run_id, phase_key: "complete_existing_pr_run", phase_group: "post", agent_run: agent_run, metadata: @phase_metadata) do
        project = agent_run.project
        client = project.client

        pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)
        enforce_conflict_repair_scope!(client, agent_run, pr)
        record_shipped_verification_result(agent_run)

        # A blocked completion-verification gate is a deterministic project
        # failure (the gate's decision cannot change without operator
        # action), so the raise is rescued here to refresh the existing PR
        # body and post the same update comment that would have run on
        # success before re-raising. Without this rescue the workflow
        # rescue marks the run failed but the existing PR body and
        # followup comment trail are never updated for the new push, and
        # a retry under DEFAULT_RETRY_POLICY's 3 attempts would still skip
        # the work because the raise propagates before refresh/comment
        # run.
        completed = begin
          agent_run.complete!(
            result_commit: agent_run.result_commit_sha,
            pr_url: pr.html_url,
            pr_number: pr.number
          )
        rescue AppleVerificationAttempts::GateEnforcement::RequiredVerificationFailed
          refresh_pull_request_body(client, project, pr, agent_run)
          post_update_comment_unless_already_posted(client, project, pr.number, agent_run)
          agent_run.log!("system", "PR update blocked by required Apple verification failure: #{pr.html_url}")
          raise
        end

        # A pending required verification leaves the run active. Refresh its
        # review surface, but do not perform any success-only post-processing.
        # @spec APPLE-ATTEMPT-013
        unless completed
          refresh_pull_request_body(client, project, pr, agent_run)
          return result(agent_run.reload)
        end

        record_draft_review_round_if_needed(agent_run)
        capture_session_summary_if_needed(agent_run)
        refresh_pull_request_body(client, project, pr, agent_run)
        publish_tdd_test_revision(agent_run, pr.number)
        post_update_comment(client, project, pr.number, agent_run)

        agent_run.log!("system", "Pushed updates to existing PR: #{pr.html_url}")

        issue = agent_run.issue
        if issue && !(issue.is_pull_request? && issue.draft_phase?)
          issue.complete_unless_reopen_review_pending!
        end

        logger.info(
          message: "agent_execution.existing_pr_completed",
          agent_run_id: agent_run_id,
          pull_request_url: pr.html_url
        )

        ProcessRunQueueJob.perform_later

        result(agent_run)
      end
    end

    private

    # The enclosing deadline is finite: internal budgets derive from the
    # activity's actual Temporal start-to-close deadline rather than stacking
    # independent fixed timeouts. Falls back to the workflow's configured
    # deadline outside a real activity context (e.g. unit tests).
    # @spec AUTO-MERGE-011 TEMPORAL-ORCHESTRATION-018
    def activity_deadline
      info = Temporalio::Activity::Context.current_or_nil&.info
      return monotonic_now + DEFAULT_ACTIVITY_DEADLINE_SECONDS unless info&.start_to_close_timeout

      monotonic_now + [ (info.started_time + info.start_to_close_timeout - Time.now).to_f, 0 ].max
    end

    def remaining_activity_seconds
      [ @activity_deadline - monotonic_now, 0 ].max
    end

    def assessment_budget_seconds
      bounded_request_budget(cap: ConflictRepairs::AssessScope::TIMEOUT)
    end

    def summary_budget_seconds
      bounded_request_budget(cap: Llm::GenerateAgentUpdateSummary::TIMEOUT)
    end

    def bounded_request_budget(cap:)
      [ remaining_activity_seconds - PUBLICATION_RESERVE_SECONDS, cap ].min
    end

    def publication_budget_seconds
      remaining_activity_seconds - STOP_RESERVE_SECONDS
    end

    def result(agent_run)
      {
        agent_run_id: agent_run.id,
        pull_request_url: agent_run.pull_request_url,
        pull_request_number: agent_run.pull_request_number,
        pr_review_phase: agent_run.issue&.pr_review_phase,
        tdd_returned_to_test_review: agent_run.tdd_returned_to_test_review?,
        skipped: agent_run.pull_request_url.blank?,
        cancelled: agent_run.status == "cancelled"
      }
    end

    # @spec QUIET-MODE-007
    def post_update_comment(client, project, pr_number, agent_run)
      return unless project.upstream_feature_enabled?(:upstream_issue_comments)
      # Quiet mode skips the per-push summary comment — the agent's commit
      # message is the only commentary channel left (#4232).
      return if quiet_mode?(project)
      return unless summary_comments_enabled?(agent_run)

      body = build_comment_body(client, project, pr_number, agent_run)
      return if body.blank?

      client.add_comment(project.full_name, pr_number, body)
    rescue RejectionPublicationDeadlineExceeded
      raise
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.existing_pr_comment_failed",
        agent_run_id: agent_run.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error: e.message
      )
    end

    def post_update_comment_unless_already_posted(client, project, pr_number, agent_run)
      return if quiet_mode?(project)
      return if client.issue_comments(project.full_name, pr_number).any? { |comment| self.class.agent_update_comment?(comment.body) }

      post_update_comment(client, project, pr_number, agent_run)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.existing_pr_comment_lookup_failed",
        agent_run_id: agent_run.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error: e.message
      )
    end

    def quiet_mode?(project)
      project.respond_to?(:quiet_mode?) && project.quiet_mode?
    end

    # Re-evaluates the PR gate after PushBranchActivity has persisted the
    # shipped SHA. The earlier post-run recording precedes that push and can
    # only bind a bundle-based attempt.
    # @spec APPLE-ATTEMPT-011
    def record_shipped_verification_result(agent_run)
      return if agent_run.worktree_path.blank?

      AgentRuns::VerificationResultRecorder.call(
        agent_run: agent_run,
        repo_path: agent_run.worktree_path,
        fallback_result: agent_run.verification_result,
        record_missing: false,
        result_commit: agent_run.result_commit_sha
      )
    end

    # @spec TDD-PR-001
    def refresh_pull_request_body(client, project, pr, agent_run)
      updated_body = PullRequests::ReviewSurface.call(body: pr.body.to_s, agent_run: agent_run)
      return if updated_body == pr.body.to_s

      client.update_pull_request(project.full_name, pr.number, body: updated_body)
      sync_pull_request_record(client, project, pr.number)
    rescue RejectionPublicationDeadlineExceeded
      raise
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.existing_pr_body_refresh_failed",
        agent_run_id: agent_run.id,
        pr_number: pr.number,
        error_class: e.class.name,
        error: e.message
      )
    end

    # @spec TDD-PR-007
    def publish_tdd_test_revision(agent_run, pr_number)
      result = Tdd::PublishTestRevision.call(agent_run: agent_run, pull_request_number: pr_number)
      return if result.success? || result.error == :not_test_writing_phase

      logger.warn(
        message: "tdd.publish_test_revision_failed",
        agent_run_id: agent_run.id,
        pull_request_number: pr_number,
        reason: result.error
      )
    end

    # The coherence soft-block is intentionally NOT appended to followup
    # comments. The repo-wide coherence state is identical across runs in a
    # review cycle, so posting it on every followup buries useful signal
    # under dozens of identical comments (#3272). It remains in the PR body
    # (CreatePullRequestActivity, per LID-RUNS-003) and in structured logs +
    # agent-run metadata (Lid::CoherenceCheck).
    def build_comment_body(client, project, pr_number, agent_run)
      repair_explanation = conflict_repair_explanation(agent_run)
      summary = generate_summary(client, project, pr_number, agent_run) if summary_comment_requested?(agent_run)
      return if repair_explanation.blank? && summary.blank?

      sections = [ repair_explanation, summary ].compact.join("\n\n")
      "#{COMMENT_MARKER}\n#{SUMMARY_PREFIX}\n\n#{sections}"
    end

    # The assessment is a completion gate, not merely an explanation. It keeps
    # base-branch imports distinct from the agent-authored repair evidence.
    # @spec AUTO-MERGE-010
    def conflict_repair_explanation(agent_run)
      return unless agent_run.focus == "merge_conflict"

      base_sha = summary_base_sha(agent_run)
      head_sha = agent_run.result_commit_sha
      return if base_sha.blank? || head_sha.blank?

      assessment = conflict_repair_scope_assessment(agent_run, base_sha:, head_sha:)
      comparison_url = conflict_repair_range_url(agent_run)
      <<~MARKDOWN.strip
        ## Automatic conflict repair

        Paid ran because automatic rebase against the base branch found conflicts. #{conflict_repair_scope_message(assessment)} [Compare the repair range on GitHub](#{comparison_url}).

        A prior approval remains valid only if Paid's freshness check classifies the range as content-preserving. Conflict-resolution edits or any other author-side content require review of the current revision; this update does not enable automatic merging when that project policy is inactive.
      MARKDOWN
    end

    # The durable typed stop for a non-approved scope decision. The assessment
    # and its durable persistence always precede PR publication, and the
    # publication attempt is bounded by the remaining deadline so slow or hung
    # GitHub calls can neither consume the activity's attempts nor replace
    # this actionable classification with a generic timeout (#5310).
    # @spec AUTO-MERGE-011
    def enforce_conflict_repair_scope!(client, agent_run, pr)
      return unless agent_run.focus == "merge_conflict"

      pre_run_sha = summary_base_sha(agent_run)
      base_sha = pr.base&.sha
      head_sha = agent_run.result_commit_sha
      assessment = assess_conflict_repair_scope(client, agent_run, pre_run_sha:, base_sha:, head_sha:)
      return if assessment["status"] == "approved"

      publish_conflict_repair_rejection(client, agent_run, pr)
      raise Temporalio::Error::ApplicationError.new(
        "Automatic conflict repair requires human review: #{assessment.fetch("explanation")}",
        type: "ConflictRepairScopeRejected",
        non_retryable: true
      )
    end

    # An activity retry reuses the persisted assessment bound to the exact
    # pre-run, integration-base, and pushed head SHAs instead of issuing
    # another harness request, so retries add no LLM spend (#5310).
    # @spec AUTO-MERGE-011
    def assess_conflict_repair_scope(client, agent_run, pre_run_sha:, base_sha:, head_sha:)
      reusable = reusable_conflict_repair_assessment(agent_run, pre_run_sha:, base_sha:, head_sha:)
      return reusable if reusable

      started = monotonic_now
      budget = assessment_budget_seconds
      assessment = if pre_run_sha.blank? || base_sha.blank? || head_sha.blank?
        ConflictRepairs::AssessScope::Result.new(status: "unavailable", explanation: "Repair comparison commits were unavailable", base_imported_paths: [], repair_authored_paths: [])
      elsif budget < MINIMUM_REQUEST_SECONDS
        ConflictRepairs::AssessScope::Result.new(status: "unavailable", explanation: "Scope assessment exceeded the enclosing activity deadline", base_imported_paths: [], repair_authored_paths: [])
      else
        # Comparison I/O draws from the same finite enclosing deadline as the
        # request it feeds: the reads are bounded by the assessment budget so
        # a hung GitHub compare cannot consume the activity's deadline.
        base_comparison, result_comparison = Timeout.timeout(budget, ComparisonDeadlineExceeded) do
          [
            client.compare_summary(agent_run.project.full_name, pre_run_sha, base_sha),
            client.compare_summary(agent_run.project.full_name, pre_run_sha, head_sha)
          ]
        end
        # The reads consumed real deadline time: admit the request only
        # against what actually remains after them (#5316).
        budget = assessment_budget_seconds
        ConflictRepairs::AssessScope.call(
          agent_run: agent_run,
          base_comparison: base_comparison,
          result_comparison: result_comparison,
          timeout: budget
        )
      end
      record_assessment_diagnostics(budget:, elapsed_seconds: monotonic_now - started, status: assessment.status)
      persist_conflict_repair_scope_assessment(agent_run, assessment.to_h.merge("base_sha" => pre_run_sha, "integration_base_sha" => base_sha, "head_sha" => head_sha))
    rescue GithubClient::Error, ComparisonDeadlineExceeded => e
      logger.warn(message: "agent_execution.conflict_repair_scope_assessment_failed", agent_run_id: agent_run.id, error_class: e.class.name, error: e.message)
      record_assessment_diagnostics(budget: assessment_budget_seconds, elapsed_seconds: monotonic_now - started, status: "unavailable")
      persist_conflict_repair_scope_assessment(agent_run, unavailable_assessment(pre_run_sha, base_sha, head_sha))
    end

    def reusable_conflict_repair_assessment(agent_run, pre_run_sha:, base_sha:, head_sha:)
      stored = agent_run.external_metadata[CONFLICT_REPAIR_SCOPE_ASSESSMENT_KEY]
      return unless stored.is_a?(Hash) &&
        stored["base_sha"] == pre_run_sha &&
        stored["integration_base_sha"] == base_sha &&
        stored["head_sha"] == head_sha &&
        stored["status"].present?

      logger.info(
        message: "agent_execution.conflict_repair_scope_assessment_reused",
        agent_run_id: agent_run.id,
        scope_status: stored["status"]
      )
      @phase_metadata["scope_assessment_reused"] = true
      @phase_metadata["scope_assessment_status"] = stored["status"]
      stored
    end

    # Bounded, best-effort publication of the rejection. Never allowed to
    # displace the typed stop: the wrapper abandons whatever has not finished
    # within the remaining publication budget.
    # @spec AUTO-MERGE-011
    def publish_conflict_repair_rejection(client, agent_run, pr)
      started = monotonic_now
      budget = publication_budget_seconds
      skipped = budget < MINIMUM_REQUEST_SECONDS
      if skipped
        logger.warn(
          message: "agent_execution.conflict_repair_rejection_publication_skipped",
          agent_run_id: agent_run.id,
          pr_number: pr.number,
          publication_budget_seconds: budget.round(2)
        )
      else
        Timeout.timeout(budget, RejectionPublicationDeadlineExceeded) do
          refresh_pull_request_body(client, agent_run.project, pr, agent_run)
          post_conflict_repair_rejection_comment(client, agent_run, pr)
        end
      end
    rescue RejectionPublicationDeadlineExceeded
      logger.warn(
        message: "agent_execution.conflict_repair_rejection_publication_timed_out",
        agent_run_id: agent_run.id,
        pr_number: pr.number,
        publication_budget_seconds: budget.round(2)
      )
    ensure
      record_publication_diagnostics(elapsed_seconds: monotonic_now - started, skipped:)
    end

    # At most one rejection comment per repair range: a retried attempt that
    # already posted for this exact pre-run..head range must not duplicate it.
    # @spec AUTO-MERGE-011
    def post_conflict_repair_rejection_comment(client, agent_run, pr)
      project = agent_run.project
      return unless project.upstream_feature_enabled?(:upstream_issue_comments)
      return if quiet_mode?(project)
      return if rejection_comment_already_posted?(client, project, pr.number, agent_run)

      body = build_comment_body(client, project, pr.number, agent_run)
      return if body.blank?

      client.add_comment(project.full_name, pr.number, body)
    rescue RejectionPublicationDeadlineExceeded
      raise
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.existing_pr_comment_failed",
        agent_run_id: agent_run.id,
        pr_number: pr.number,
        error_class: e.class.name,
        error: e.message
      )
    end

    def rejection_comment_already_posted?(client, project, pr_number, agent_run)
      range_url = conflict_repair_range_url(agent_run)
      return false if range_url.blank?

      client.issue_comments(project.full_name, pr_number).any? do |comment|
        self.class.agent_update_comment?(comment.body) && comment.body.include?(range_url)
      end
    rescue RejectionPublicationDeadlineExceeded
      raise
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      # A failed duplicate lookup must not suppress the review request: post
      # rather than silently drop the rejection explanation.
      logger.warn(
        message: "agent_execution.existing_pr_comment_lookup_failed",
        agent_run_id: agent_run.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def conflict_repair_range_url(agent_run)
      base_sha = summary_base_sha(agent_run)
      head_sha = agent_run.result_commit_sha
      return if base_sha.blank? || head_sha.blank?

      "#{agent_run.project.github_url}/compare/#{base_sha}...#{head_sha}"
    end

    def record_assessment_diagnostics(budget:, elapsed_seconds:, status:)
      @phase_metadata.merge!(
        "scope_assessment_status" => status,
        "assessment_budget_seconds" => budget.round(2),
        "assessment_elapsed_ms" => (elapsed_seconds * 1000).round
      )
    end

    def record_publication_diagnostics(elapsed_seconds:, skipped: false)
      @phase_metadata.merge!(
        "rejection_publication_skipped" => skipped,
        "publication_elapsed_ms" => (elapsed_seconds * 1000).round
      )
    end

    def conflict_repair_scope_assessment(agent_run, base_sha:, head_sha:)
      stored_assessment = agent_run.external_metadata[CONFLICT_REPAIR_SCOPE_ASSESSMENT_KEY]
      return stored_assessment if stored_assessment_matches?(stored_assessment, base_sha:, head_sha:)

      unavailable_assessment(base_sha, nil, head_sha)
    end

    def stored_assessment_matches?(assessment, base_sha:, head_sha:)
      assessment.is_a?(Hash) &&
        assessment["base_sha"] == base_sha &&
        assessment["head_sha"] == head_sha
    end

    def persist_conflict_repair_scope_assessment(agent_run, assessment)
      metadata = agent_run.external_metadata.deep_dup
      agent_run.update!(external_metadata: metadata.merge(CONFLICT_REPAIR_SCOPE_ASSESSMENT_KEY => assessment))
      assessment
    end

    def conflict_repair_scope_message(assessment)
      return "Paid could not retrieve repair-range evidence, so scope was requested but not independently verified." if assessment["status"] == "unavailable"

      base_count = assessment.fetch("base_imported_paths", []).size
      repair_count = assessment.fetch("repair_authored_paths", []).size
      decision = assessment["status"] == "approved" ? "accepted as in scope" : "rejected and requires human review"
      "Paid classified #{base_count} base-import #{'path'.pluralize(base_count)} and #{repair_count} repair-authored #{'path'.pluralize(repair_count)}; the repair was #{decision}."
    end

    def unavailable_assessment(base_sha, integration_base_sha, head_sha)
      {
        "status" => "unavailable",
        "explanation" => "Repair comparison evidence was unavailable",
        "base_sha" => base_sha,
        "integration_base_sha" => integration_base_sha,
        "head_sha" => head_sha,
        "base_imported_paths" => [],
        "repair_authored_paths" => []
      }
    end

    def summary_comments_enabled?(agent_run)
      agent_run.focus == "merge_conflict" || summary_comment_requested?(agent_run)
    end

    def summary_comment_requested?(agent_run)
      agent_run.settings_user&.settings&.agent_update_comment_mode == SUMMARY_COMMENT_MODE
    end

    def generate_summary(client, project, pr_number, agent_run)
      summary_base_sha = summary_base_sha(agent_run)
      return if summary_base_sha.blank? || agent_run.result_commit_sha.blank?

      budget = summary_budget_seconds
      return if budget < MINIMUM_REQUEST_SECONDS

      comparison = summary_comparison(client, project, summary_base_sha, agent_run, bound: budget)
      # The read consumed real deadline time: admit the request only against
      # what actually remains after it (#5316).
      budget = summary_budget_seconds
      return if comparison.blank? || budget < MINIMUM_REQUEST_SECONDS

      result = Llm::GenerateAgentUpdateSummary.call(
        agent_run: agent_run,
        repository: project.full_name,
        pr_number: pr_number,
        base_sha: summary_base_sha,
        head_sha: agent_run.result_commit_sha,
        comparison: comparison,
        timeout: budget
      )
      track_summary_tokens(agent_run, result&.response)
      result&.body
    end

    # The summary comparison read draws from the same finite enclosing
    # deadline as the summary request it feeds: bounded by that budget, and
    # its elapsed time is deducted before the request is admitted. A read
    # that exceeds the budget degrades to a skipped summary rather than a
    # failed completion (#5316).
    # @spec TEMPORAL-ORCHESTRATION-018
    def summary_comparison(client, project, base_sha, agent_run, bound:)
      Timeout.timeout(bound, ComparisonDeadlineExceeded) do
        client.compare_summary(project.full_name, base_sha, agent_run.result_commit_sha)
      end
    rescue ComparisonDeadlineExceeded
      logger.warn(
        message: "agent_execution.update_summary_comparison_timed_out",
        agent_run_id: agent_run.id,
        repository: project.full_name
      )
      nil
    end

    def summary_base_sha(agent_run)
      agent_run.external_metadata["pre_run_head_sha"].presence
    end

    def track_summary_tokens(agent_run, response)
      return unless response&.respond_to?(:tokens) && response.tokens

      TokenUsageTracker.track(
        tracked_run: agent_run,
        usage: {
          tokens_input: response.respond_to?(:input_tokens) ? response.input_tokens.to_i : 0,
          tokens_output: response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0,
          llm_model: response.respond_to?(:model) ? response.model : nil,
          request_type: "agent",
          metadata: { operation: "agent_update_summary" }
        },
        enforce_guardrails: false
      )
    end

    # @spec TDD-PR-001
    def sync_pull_request_record(client, project, pr_number)
      github_issue = client.issue(project.full_name, pr_number)
      Issues::UpsertFromGithub.call(project: project, github_issue: github_issue)
    end
  end
end
