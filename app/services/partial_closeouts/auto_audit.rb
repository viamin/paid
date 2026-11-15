# frozen_string_literal: true

module PartialCloseouts
  # Schedules one report-only audit after terminal closeout evidence appears.
  # The issue lock covers the historical-attempt check and admission so
  # overlapping sweeps cannot schedule the same retry. Transient-failure
  # retries are claimed through the shared retry mechanism
  # (docs/intent/agent-run-retry-contract/); a fresh logical audit for
  # changed terminal evidence goes through ordinary audit admission.
  # @spec PARTIAL-CLOSEOUT-037 TRUSTED-MEASUREMENTS-006 PARTIAL-CLOSEOUT-051 PARTIAL-CLOSEOUT-056
  class AutoAudit
    MAX_ATTEMPTS = 3
    RETRY_DELAY = 30.minutes
    Result = Data.define(:agent_run, :code) do
      def scheduled? = agent_run.present?
      def self.success(agent_run) = new(agent_run:, code: nil)
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return result(:automation_disabled) unless Issues::AutoPickProjectGate.call(issue.project)

      issue.with_lock do
        status = Issues::CloseoutStatus.call(issue)
        return result(:not_stalled) unless stalled_or_refreshable?(status)
        assessment = Assessment.call(
          issue, evidence: status.evidence, technical_evidence: status.technical_evidence
        )
        return result(:assessment_current) unless assessment.stale?
        return result(:blocked) if status.blockers.any? { |blocker| blocker.code != :human_prerequisite_notification }

        decision = AcceptanceAuditRetryPolicy.sweep_decision(
          issue, source_revision: assessment.current_source_revision, intent_revision: Assessment.intent_revision_for(issue)
        )
        return result(decision.refusal) if decision.refused?
        return claim_retry(decision.retry_run) if decision.retry_run

        request = Issues::RequestAcceptanceAudit.call(issue:, actor: issue.project.effective_owner, origin: :automatic)
        Result.new(agent_run: request.agent_run, code: request.code)
      end
    end

    private

    attr_reader :issue

    # A human prerequisite notification remains an implementation and closure
    # hold. It is the one stale assessment blocker an audit may inspect so it
    # can determine the current supported recovery action (#5057).
    def stalled_or_refreshable?(status)
      return true if status.stalled?

      status.blockers.any? && status.blockers.all? do |blocker|
        blocker.code == :human_prerequisite_notification
      end
    end

    # A due transient retry is claimed through the shared mechanism so the
    # sweep, the delayed retry job, and operator requests converge on one
    # idempotent claim with a durable decision record.
    def claim_retry(retry_run)
      claimed = AcceptanceAuditRetryPolicy.retry_mechanism.claim(
        agent_run_id: retry_run.id, attempt: next_attempt_for(retry_run)
      )
      return Result.new(agent_run: nil, code: claimed.reason) unless claimed.claimed?

      Result.success(claimed.successor)
    end

    def next_attempt_for(retry_run)
      AcceptanceAuditRetryPolicy.new.next_attempt(retry_run)
    end

    def result(code) = Result.new(agent_run: nil, code:)
  end
end
