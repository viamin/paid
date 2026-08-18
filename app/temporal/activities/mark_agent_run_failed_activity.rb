# frozen_string_literal: true

module Activities
  class MarkAgentRunFailedActivity < BaseActivity
    activity_name "MarkAgentRunFailed"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      error = input[:error]
      agent_run = AgentRun.find(agent_run_id)

      agent_run.with_lock do
        agent_run.reload

        # Don't overwrite a more specific terminal status (e.g. "timeout")
        # that was already set by the activity that detected the failure.
        if agent_run.finished?
          agent_run.log!("system", "Agent run already #{agent_run.status}, skipping fail! (error: #{error})")
        else
          agent_run.fail!(error: error)
          agent_run.log!("system", "Agent run failed: #{error}")
        end
      end
      # @spec FOCUSED-RUN-006
      record_draft_review_round_if_needed(agent_run)

      # Always trigger queue processing so remaining queued runs get claimed.
      # This is safe because ProcessRunQueueJob is idempotent (advisory lock +
      # SKIP LOCKED). Without this, runs that were already marked failed by
      # RunAgentActivity would skip queue processing entirely.
      ProcessRunQueueJob.perform_later

      # Update issue state for failure statuses so it doesn't stay stuck in
      # "in_progress". Preserve cancellation and successful terminal states.
      # Review-goal failures restore the issue to "completed" rather than
      # marking it "failed" — the underlying PR work succeeded; only the
      # follow-up review run failed. Using "completed" keeps auto-pick
      # unblocked and lets the scanner re-evaluate the PR on the next cycle.
      #
      # Recoverable rate-limited runs (runner unavailable / transient infra,
      # awaiting an in-place re-queue by StaleRunDetectorJob) keep the issue
      # "in_progress": flipping it to "failed" would arm the auto-pick re-enqueue
      # pump and mint a duplicate run that supersedes this one — the churn loop
      # that caused hundreds of wasted runs per issue.
      if agent_run.issue && agent_run.status.in?(AgentRun::FAILURE_STATUSES)
        target_state =
          if agent_run.recoverable_rate_limited?
            "in_progress"
          elsif agent_run.review_goal?
            "completed"
          else
            "failed"
          end
        if agent_run.issue.paid_state != target_state
          agent_run.issue.update!(paid_state: target_state)
        end

        # A GitHub App permission rejection is permanent — it fails identically
        # on every retry until the App's permissions change (e.g. granting the
        # workflows permission) or a PAT push fallback is enabled. Abandon the
        # issue from auto-pick so it doesn't re-enqueue into an infinite loop,
        # and surface the actionable cause on the issue. Only issue-scoped
        # create/analyze goals re-enqueue; review and other goals don't loop.
        if agent_run.push_permission_rejection? && agent_run.goal.in?(%w[create_pr analyze_issue])
          handle_push_permission_rejection(agent_run)
        end
      end

      logger.info(
        message: "agent_execution.failed",
        agent_run_id: agent_run_id,
        error: error
      )

      check_auth_failure(agent_run, error)

      { agent_run_id: agent_run_id }
    end

    private

    PUSH_PERMISSION_COMMENT_MARKER = "<!-- paid: push-permission-rejection -->"

    def check_auth_failure(agent_run, error_message)
      checker = GithubTokens::AuthFailureChecker.new(error_message: error_message)
      matched_pattern = checker.call
      return unless matched_pattern

      github_token = agent_run.project&.github_token
      return unless github_token

      logger.info(
        message: "github_token.auth_failure_check",
        agent_run_id: agent_run.id,
        token_id: github_token.id,
        error_pattern: matched_pattern.source
      )

      GithubTokenValidationJob.perform_later(github_token.id)
    rescue => e
      logger.warn(
        message: "github_token.auth_failure_check_error",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end

    # Parks the issue from auto-pick (so the missing-permission push rejection
    # can't loop) and posts a comment explaining the actionable cause. Never
    # raises — the run is already marked failed, so a comment/abandon error
    # must not block queue processing or other bookkeeping.
    def handle_push_permission_rejection(agent_run)
      issue = agent_run.issue
      return unless issue

      reason = "the GitHub App installation token lacks the `workflows` permission " \
               "for a push under `.github/workflows/`. Grant the App the workflows " \
               "permission (or enable the project's PAT push fallback) and re-trigger " \
               "the run."
      issue.abandon_due_to_push_permission_rejection!(reason: reason)
      post_push_permission_comment(agent_run, issue)
    rescue => e
      logger.warn(
        message: "agent_execution.push_permission_rejection_handling_failed",
        agent_run_id: agent_run.id,
        issue_id: issue&.id,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end

    def post_push_permission_comment(agent_run, issue)
      project = agent_run.project
      client = project&.client
      return unless project && client && issue.github_number.present?
      return if push_permission_comment_present?(client, project, issue)

      body = [
        PUSH_PERMISSION_COMMENT_MARKER,
        "**Push blocked: missing GitHub App permission**",
        "",
        "Paid could not push this change because the `paid-agents` GitHub App " \
          "installation token lacks the `workflows` permission for a change under " \
          "`.github/workflows/`. This is permanent until the App's permissions change, " \
          "so the issue is parked from automatic retries to avoid a loop.",
        "",
        "**Next steps:**",
        "- Grant the `paid-agents` App the `workflows` permission (and approve it), or",
        "- Enable the project's PAT push fallback with a workflow-scoped PAT.",
        "",
        "Then re-trigger the run to resume."
      ].join("\n")

      client.add_comment(project.full_name, issue.github_number, body)
      logger.info(
        message: "github_integration.push_permission_comment_posted",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "github_integration.push_permission_comment_failed",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end

    def push_permission_comment_present?(client, project, issue)
      comments = client.recent_issue_comments(project.full_name, issue.github_number)
      comments.any? { |comment| comment.respond_to?(:body) && comment.body&.include?(PUSH_PERMISSION_COMMENT_MARKER) }
    rescue GithubClient::Error => e
      logger.warn(
        message: "github_integration.push_permission_comment_check_failed",
        issue_id: issue.id,
        issue_number: issue.github_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
      false
    end
  end
end
