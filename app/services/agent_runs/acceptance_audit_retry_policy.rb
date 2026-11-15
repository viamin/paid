# frozen_string_literal: true

module AgentRuns
  # Acceptance-audit policy for the shared retry mechanism
  # ({AgentRuns::RetryAttempt}). The audit's logical identity is the issue
  # plus the closeout-evidence source revision: every execution attempt
  # under that identity is one continuation request and run, so a fresh
  # logical audit needs new terminal evidence rather than another attempt.
  # Only a transient transport/infrastructure failure that left no usable
  # assessment may claim another bounded attempt
  # ({PartialCloseouts::AcceptanceAuditFailure}); the claim itself is owned
  # by {PartialCloseouts::RetryAcceptanceAudit}, which serializes on the
  # issue because that is where this path's identity lives.
  # @spec PARTIAL-CLOSEOUT-056 AGENT-RETRY-014
  class AcceptanceAuditRetryPolicy
    SKIP_REASONS = {
      substantive_assessment: :substantive_assessment_recorded,
      cancelled: :cancelled,
      authentication_or_configuration: :authentication_or_configuration,
      rate_limit_recovery_owned: :rate_limit_recovery_owned,
      budget_exhausted: :budget_exhausted,
      non_transient_failure: :non_transient_failure,
      not_terminal: :not_terminal
    }.freeze

    Assessment = Data.define(:eligible?, :reason, :attempt)

    class << self
      def acceptance_audit_run?(agent_run)
        agent_run.continuation_request&.evidence.to_h.fetch("continuation_mode", "implementation") == "acceptance_audit"
      end
    end

    def assess(agent_run, attempt: next_attempt(agent_run))
      return Assessment.new(false, :not_acceptance_audit, attempt) unless self.class.acceptance_audit_run?(agent_run)
      return Assessment.new(false, :already_retried, attempt) if agent_run.status == "retried"
      return Assessment.new(false, :retry_budget_exhausted, attempt) if attempt_count(agent_run) >= maximum_attempts

      classification = PartialCloseouts::AcceptanceAuditFailure.classify(agent_run)
      unless classification == :transient_transport
        return Assessment.new(false, SKIP_REASONS.fetch(classification, :non_transient_failure), attempt)
      end
      return Assessment.new(false, :evidence_changed, attempt) if evidence_changed?(agent_run)
      return Assessment.new(false, :open_request_present, attempt) if IssueContinuationRequest.open_for_issue(agent_run.issue).present?

      Assessment.new(true, :eligible, attempt)
    end

    def next_attempt(agent_run)
      attempt_count(agent_run) + 1
    end

    def maximum_attempts
      PartialCloseouts::AutoAudit::MAX_ATTEMPTS
    end

    # Attempts already executed against this run's logical identity: every
    # run whose continuation request recorded the same source revision,
    # including operator-requested attempts and attempts made under earlier
    # approved-intent revisions.
    def attempt_count(agent_run)
      AgentRun.where(continuation_request: requests_for(agent_run)).count
    end

    def logical_source_revision(agent_run)
      agent_run.continuation_request&.evidence.to_h["source_revision"]
    end

    private

    def requests_for(agent_run)
      revision = logical_source_revision(agent_run)
      return IssueContinuationRequest.none if revision.blank? || agent_run.issue_id.blank?

      IssueContinuationRequest.where(issue_id: agent_run.issue_id)
        .where("evidence->>'source_revision' = ?", revision)
        .where("evidence->>'continuation_mode' = ?", "acceptance_audit")
    end

    def evidence_changed?(agent_run)
      revision = logical_source_revision(agent_run)
      return true if revision.blank? || agent_run.issue.blank?

      PartialCloseouts::Assessment.source_revision_for(agent_run.issue) != revision
    end
  end
end
