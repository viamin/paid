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
      if agent_run.issue && agent_run.status.in?(AgentRun::FAILURE_STATUSES)
        target_state = agent_run.review_goal? ? "completed" : "failed"
        if agent_run.issue.paid_state != target_state
          agent_run.issue.update!(paid_state: target_state)
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
  end
end
