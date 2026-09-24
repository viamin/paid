# frozen_string_literal: true

module Activities
  # Completes an agent run that pushed to an existing PR's branch.
  # Marks the run as completed with the existing PR's URL/number
  # and adds a comment to the PR noting the agent pushed updates.
  class CompleteExistingPrRunActivity < BaseActivity
    activity_name "CompleteExistingPrRun"
    COMMENT_MARKER = "<!-- paid:agent-update -->"
    SUMMARY_PREFIX = "## Agent Update"
    GENERIC_MESSAGE = "Agent pushed updates to this PR."
    SUMMARY_COMMENT_MODE = "summary"

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

      track_phase(agent_run_id: agent_run_id, phase_key: "complete_existing_pr_run", phase_group: "post", agent_run: agent_run) do
        project = agent_run.project
        client = project.client

        pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)
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
        post_update_comment(client, project, pr.number, agent_run)

        agent_run.log!("system", "Pushed updates to existing PR: #{pr.html_url}")

        issue = agent_run.issue
        if issue && !(issue.is_pull_request? && issue.draft_phase?)
          issue.update!(paid_state: "completed")
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

    def post_update_comment(client, project, pr_number, agent_run)
      body = build_comment_body(client, project, pr_number, agent_run)
      return if body.blank?

      client.add_comment(project.full_name, pr_number, body)
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

    # The coherence soft-block is intentionally NOT appended to followup
    # comments. The repo-wide coherence state is identical across runs in a
    # review cycle, so posting it on every followup buries useful signal
    # under dozens of identical comments (#3272). It remains in the PR body
    # (CreatePullRequestActivity, per LID-RUNS-003) and in structured logs +
    # agent-run metadata (Lid::CoherenceCheck).
    def build_comment_body(client, project, pr_number, agent_run)
      summary = summary_comments_enabled?(agent_run) ? generate_summary(client, project, pr_number, agent_run) : nil
      return if summary.blank?

      "#{COMMENT_MARKER}\n#{SUMMARY_PREFIX}\n\n#{summary}"
    end

    def summary_comments_enabled?(agent_run)
      agent_run.settings_user&.settings&.agent_update_comment_mode == SUMMARY_COMMENT_MODE
    end

    def generate_summary(client, project, pr_number, agent_run)
      summary_base_sha = summary_base_sha(agent_run)
      return if summary_base_sha.blank? || agent_run.result_commit_sha.blank?

      comparison = client.compare_summary(project.full_name, summary_base_sha, agent_run.result_commit_sha)
      result = Llm::GenerateAgentUpdateSummary.call(
        repository: project.full_name,
        pr_number: pr_number,
        base_sha: summary_base_sha,
        head_sha: agent_run.result_commit_sha,
        comparison: comparison
      )
      track_summary_tokens(agent_run, result&.response)
      result&.body
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
