# frozen_string_literal: true

module PartialCloseouts
  # Acceptance-audit adapter for the shared retry mechanism
  # (`AgentRuns::RetryAttempt`, docs/intent/agent-run-retry-contract/).
  # Logical identity is the issue plus the closeout-evidence source revision
  # the audit was admitted against, so a fresh logical audit requires changed
  # terminal evidence; execution attempts under one identity are bounded,
  # spaced by increasing backoff, and claimed idempotently under lock.
  # Successor runs are minted through ordinary audit admission
  # (`Issues::RequestAcceptanceAudit`), never by copying a row.
  # @spec PARTIAL-CLOSEOUT-048 PARTIAL-CLOSEOUT-056 AGENT-RETRY-014
  class AcceptanceAuditRetryPolicy
    Assessment = Data.define(:eligible?, :reason, :attempt) do
      def self.skip(reason, attempt) = new(false, reason, attempt)
      def self.admit(attempt) = new(true, :eligible, attempt)
    end

    # Sweep-facing admission for another automatic attempt against the
    # current evidence generation: `refusal` names the stopping reason (or
    # nil when an attempt is admissible) and `retry_run` names the terminal
    # attempt the shared mechanism should claim when the admissible attempt
    # is a retry rather than a fresh audit.
    SweepDecision = Data.define(:refusal, :retry_run) do
      def refused? = refusal.present?
    end

    # An admission refusal raised inside build_successor! when ordinary
    # continuation admission changed between assess and claim; the shared
    # mechanism records it as a durable no-op with this reason.
    def self.admission_refused(reason)
      AgentRuns::RetryAttempt::AdmissionRefused.new(reason)
    end

    def self.retry_delay(attempt)
      AutoAudit::RETRY_DELAY * (2**(attempt - 2))
    end

    def self.retry_mechanism
      new.mechanism
    end

    def self.sweep_decision(issue, source_revision:, intent_revision:)
      requests = acceptance_audit_requests(issue, source_revision)
      attempts = audit_runs(requests)
      intent_runs = attempts.select { |run| intent_revision_match?(run, intent_revision) }
      refusal = sweep_refusal(attempts:, intent_runs:)
      retry_run = if refusal.nil?
        intent_runs.find { |run| AuditFailureClassification.category(run) == :transient_infrastructure }
      end
      SweepDecision.new(refusal, retry_run)
    end

    def self.sweep_refusal(attempts:, intent_runs:)
      blocking = intent_runs.find { |run| AuditFailureClassification.category(run) != :transient_infrastructure }
      return AuditFailureClassification.category(blocking) if blocking
      return :retry_exhausted if attempts.count >= AutoAudit::MAX_ATTEMPTS
      # A changed approved intent may permit a further attempt against the
      # same source revision without resetting that revision's attempt budget.
      return nil if intent_runs.empty?

      latest = intent_runs.first
      delay = AutoAudit::RETRY_DELAY * (2**(attempts.count - 1))
      :retry_backoff if latest.completed_at.blank? || latest.completed_at > delay.ago
    end

    def self.acceptance_audit_requests(issue, source_revision)
      IssueContinuationRequest.where(issue:)
        .where("evidence->>'source_revision' = ?", source_revision)
        .where("evidence->>'continuation_mode' = ?", "acceptance_audit")
    end

    # Attempts for one evidence generation, newest first. The approved-intent
    # filter also admits legacy audits that recorded their intent on the
    # run's persisted assessment instead of the request evidence.
    def self.intent_revision_match?(run, intent_revision)
      request = run.continuation_request
      recorded = request.evidence["intent_revision"]
      return true if recorded == intent_revision
      return false if recorded.present?

      run.reconciliation.to_h.dig("assessment", "intent_revision") == intent_revision ||
        run.reconciliation.to_h["assessment"].nil?
    end

    def self.audit_runs(requests)
      AgentRun.where(continuation_request_id: requests.select(:id))
        .includes(:continuation_request)
        .order(id: :desc).limit(AutoAudit::MAX_ATTEMPTS).to_a
    end

    OPEN_REQUEST_CONFLICT = "index_issue_continuation_requests_open_per_issue"

    def self.acceptance_audit_attempt?(agent_run)
      agent_run.goal == "analyze_issue" &&
        agent_run.continuation_request&.evidence&.fetch("continuation_mode", nil) == "acceptance_audit"
    end

    def mechanism
      AgentRuns::RetryAttempt.new(
        policy: self,
        decision_point: decision_action,
        action: decision_action
      )
    end

    def assess(agent_run, attempt: nil)
      return Assessment.skip(:not_acceptance_audit, attempt || 0) unless acceptance_audit_attempt?(agent_run)

      attempt ||= next_attempt(agent_run)
      return Assessment.skip(:already_retried, attempt) if agent_run.status == "retried"

      classification = AuditFailureClassification.category(agent_run)
      unless classification == :transient_infrastructure
        return Assessment.skip(classification, attempt)
      end
      return Assessment.skip(:automation_disabled, attempt) unless Issues::AutoPickProjectGate.call(agent_run.project)
      return Assessment.skip(:open_request_exists, attempt) if IssueContinuationRequest.open_for_issue(agent_run.issue)
      return Assessment.skip(:substantive_assessment, attempt) unless current_assessment_stale?(agent_run)
      return Assessment.skip(:evidence_changed, attempt) unless current_evidence_matches?(agent_run)

      spent = attempt_count(agent_run)
      return Assessment.skip(:retry_exhausted, spent) if spent >= maximum_attempts

      Assessment.admit(attempt)
    end

    def maximum_attempts
      AutoAudit::MAX_ATTEMPTS
    end

    def next_attempt(agent_run)
      attempt_count(agent_run) + 1
    end

    def decision_action
      "acceptance_audit_auto_retry"
    end

    def duplicate_conflict_reason
      :open_request_exists
    end

    def duplicate_active_run_conflict?(error)
      [ error.cause&.message, error.message ].compact.join(" ").include?(OPEN_REQUEST_CONFLICT)
    end

    def build_successor!(agent_run, _attempt)
      result = Issues::RequestAcceptanceAudit.call(
        issue: agent_run.issue, actor: agent_run.project.effective_owner, origin: :automatic
      )
      raise self.class.admission_refused(result.code) if result.agent_run.blank?

      result.agent_run
    end

    private

    def acceptance_audit_attempt?(agent_run)
      self.class.acceptance_audit_attempt?(agent_run)
    end

    def current_assessment_stale?(agent_run)
      PartialCloseouts::Assessment.call(agent_run.issue).stale?
    end

    def current_evidence_matches?(agent_run)
      admitted_revision = agent_run.continuation_request.evidence["source_revision"]
      current_revision = PartialCloseouts::Assessment.source_revision_for(agent_run.issue)
      admitted_revision == current_revision
    end

    # Every attempt against one evidence generation counts against the
    # budget, including operator-requested attempts and attempts made under
    # an earlier approved-intent revision (#5002 review).
    def attempt_count(agent_run)
      requests = self.class.acceptance_audit_requests(
        agent_run.issue, agent_run.continuation_request.evidence["source_revision"]
      )
      AgentRun.where(continuation_request_id: requests.select(:id)).count
    end
  end
end
