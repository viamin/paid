# frozen_string_literal: true

module PartialCloseouts
  # Claims the next bounded execution attempt for one acceptance-audit
  # logical identity (issue + closeout-evidence source revision) on the
  # shared retry mechanism ({AgentRuns::AcceptanceAuditRetryPolicy}). The
  # claim serializes on the issue — where this path's identity lives — and
  # re-runs the ordinary acceptance-audit request path, so every auto-pick,
  # trust, pause, dependency, budget, and one-open-request guard stays
  # authoritative, then marks the failed attempt retried with recorded
  # successor lineage. Sweep, delayed job, and operator requests converge on
  # one open request and one queued run.
  # @spec PARTIAL-CLOSEOUT-056 AGENT-RETRY-005 AGENT-RETRY-006
  class RetryAcceptanceAudit
    DECISION_POINT = "acceptance_audit_auto_retry"

    Result = Data.define(:outcome, :reason, :agent_run, :successor, :request_code) do
      def claimed? = outcome == :claimed
    end

    def self.call(agent_run_id:, attempt: nil)
      new.call(agent_run_id: agent_run_id, attempt: attempt)
    end

    def call(agent_run_id:, attempt: nil)
      agent_run = AgentRun.find_by(id: agent_run_id)
      return skipped(:missing_run, agent_run) unless agent_run
      issue = agent_run.issue
      return skipped(:missing_issue, agent_run) unless issue

      issue.with_lock do
        agent_run.reload
        # Delayed jobs carry the attempt that was next at enqueue time, but
        # operator or sweep attempts may join this source revision before it
        # runs. Derive the live number under the identity lock instead.
        attempt = policy.next_attempt(agent_run)
        assessment = policy.assess(agent_run, attempt: attempt)
        return skipped(assessment.reason, agent_run) unless assessment.eligible?
        return skipped(:retry_backoff, agent_run) unless backoff_elapsed?(agent_run)

        request = Issues::RequestAcceptanceAudit.call(issue: issue, actor: issue.project.effective_owner, origin: :automatic)
        return skipped(:request_refused, agent_run, request.code) unless request.success?

        successor = tag_successor!(request.agent_run, agent_run, attempt)
        agent_run.retry!(
          decision_point: DECISION_POINT,
          signals: retry_signals(agent_run, attempt),
          result: { new_agent_run_id: successor.id, reason: "retry_claimed" }
        )
        Rails.logger.info(
          message: "partial_closeout.acceptance_audit_retry_claimed",
          issue_id: issue.id,
          agent_run_id: agent_run.id,
          new_agent_run_id: successor.id,
          attempt: attempt
        )
        Result.new(:claimed, :retry_claimed, agent_run, successor, nil)
      end
    rescue ActiveRecord::RecordNotUnique => error
      raise unless duplicate_claim?(error)

      skipped(:concurrent_claim, AgentRun.find_by(id: agent_run_id))
    end

    private

    def policy
      @policy ||= AgentRuns::AcceptanceAuditRetryPolicy.new
    end

    def skipped(reason, agent_run, request_code = nil)
      OrchestrationDecision.record(
        project: agent_run&.project,
        agent_run: agent_run,
        decision_point: DECISION_POINT,
        action: DECISION_POINT,
        status: "noop",
        signals: { reason: reason.to_s, request_code: request_code&.to_s }.compact,
        result: { reason: reason.to_s }
      ) if agent_run&.project

      Result.new(:skipped, reason, agent_run, nil, request_code)
    end

    def backoff_elapsed?(agent_run)
      return false if agent_run.completed_at.blank?

      agent_run.completed_at <= delay_for(agent_run).ago
    end

    def delay_for(agent_run)
      AcceptanceAuditRetryJob.retry_delay(policy.attempt_count(agent_run) + 1)
    end

    def tag_successor!(successor, agent_run, attempt)
      successor.update!(external_metadata: successor.external_metadata.merge(
        AgentRun::ACCEPTANCE_AUDIT_RETRY_ATTEMPT_METADATA_KEY => attempt,
        AgentRun::ACCEPTANCE_AUDIT_RETRY_PARENT_METADATA_KEY => agent_run.id
      ))
      successor
    end

    def retry_signals(agent_run, attempt)
      {
        attempt: attempt,
        max_attempts: policy.maximum_attempts,
        source_revision: policy.logical_source_revision(agent_run)
      }
    end

    def duplicate_claim?(error)
      message = error.cause&.message || error.message
      message.include?("index_issue_continuation_requests_open_per_issue") ||
        message.include?("idx_agent_runs_unique_active_issue")
    end
  end
end
