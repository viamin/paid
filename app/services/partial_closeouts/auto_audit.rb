# frozen_string_literal: true

module PartialCloseouts
  # Schedules one report-only audit after terminal closeout evidence appears,
  # and claims the next bounded retry for a transiently failed attempt
  # through the shared retry mechanism. The issue lock covers the
  # historical-attempt check and admission so overlapping sweeps cannot
  # schedule the same retry.
  # @spec PARTIAL-CLOSEOUT-037 PARTIAL-CLOSEOUT-048 PARTIAL-CLOSEOUT-051 PARTIAL-CLOSEOUT-056 TRUSTED-MEASUREMENTS-006
  class AutoAudit
    MAX_ATTEMPTS = 3
    RETRYABLE_STATUSES = %w[failed timeout retried].freeze
    Result = Data.define(:agent_run, :code) do
      def scheduled? = agent_run.present?
    end
    RetryState = Data.define(:code, :attempts, :max_attempts)

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return result(:automation_disabled) unless Issues::AutoPickProjectGate.call(issue.project)

      issue.with_lock do
        return result(:issue_closed) unless issue.github_state == "open"
        status = Issues::CloseoutStatus.call(issue, acceptance_audit: true)
        return result(:not_stalled) unless stalled_or_refreshable?(status)
        assessment = Assessment.call(
          issue, evidence: status.evidence, technical_evidence: status.technical_evidence
        )
        return result(:assessment_current) unless AuditRefreshNeeded.call(issue:, assessment:)
        return result(:blocked) if status.blockers.any? { |blocker| blocker.code != :human_prerequisite_notification }

        decision = retry_decision(assessment.current_source_revision)
        return result(decision) if decision.is_a?(Symbol)
        return claim_retry(decision) if decision

        request = Issues::RequestAcceptanceAudit.call(issue:, actor: issue.project.effective_owner, origin: :automatic)
        Result.new(agent_run: request.agent_run, code: request.code)
      end
    end

    # Visible automatic-retry state for the issue's current evidence
    # generation: why automatic audits stopped, and how many attempts that
    # generation spent. nil when no audit attempt exists yet.
    # @spec PARTIAL-CLOSEOUT-056
    def self.retry_state(issue)
      new(issue:).retry_state
    end

    def retry_state
      requests = acceptance_audit_requests(Assessment.source_revision_for(issue))
      attempts = audit_attempt_count(requests)
      return nil if attempts.zero?

      newest = audit_runs(requests).first
      return nil if newest.blank?

      failure = AcceptanceAuditFailure.classify(newest)
      code = failure == :transient_transport && attempts >= MAX_ATTEMPTS ? :retry_exhausted : failure
      RetryState.new(code: code, attempts: attempts, max_attempts: MAX_ATTEMPTS)
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

    # Decides whether the current evidence generation's history admits
    # another attempt: a blocking Symbol, the transient-failed run to claim
    # through the shared mechanism, or nil for a fresh request under the
    # current approved intent.
    # @spec PARTIAL-CLOSEOUT-048 PARTIAL-CLOSEOUT-056
    def retry_decision(source_revision)
      requests = acceptance_audit_requests(source_revision)
      intent_runs = audit_runs(requests, intent_revision: Assessment.intent_revision_for(issue))
      return :already_audited unless intent_runs.all? { |run| retryable_failure?(run) }
      # The retry budget belongs to the source revision — the evidence
      # generation — not to the approved-intent revision. Any issue-body edit
      # changes the intent revision, so a budget keyed to it would let one edit
      # multiply the audit spend for the same evidence generation (#5002
      # review).
      attempt_count = audit_attempt_count(requests)
      return :retry_exhausted if attempt_count >= MAX_ATTEMPTS
      return if intent_runs.empty?

      newest = intent_runs.first
      if newest.completed_at.blank? || newest.completed_at > AcceptanceAuditRetryJob.retry_delay(attempt_count + 1).ago
        arm_delayed_retry(newest, attempt_count + 1)
        return :retry_backoff
      end

      newest
    end

    def retryable_failure?(run)
      run.status.in?(RETRYABLE_STATUSES) && AcceptanceAuditFailure.transient?(run)
    end

    # Claims the shared-mechanism retry under the issue lock this sweep
    # already holds. The claim re-runs the ordinary request path so every
    # normal guard is rechecked, marks the failed attempt retried, and
    # records successor lineage; sweep, delayed job, and operator requests
    # are idempotent because they converge on one open request.
    # @spec PARTIAL-CLOSEOUT-056
    def claim_retry(run)
      claim = RetryAcceptanceAudit.call(agent_run_id: run.id)
      return Result.new(agent_run: claim.successor, code: nil) if claim.claimed?

      result(claim.reason)
    end

    # Re-arms the delayed retry job from the sweep so a lost failure-time
    # schedule still recovers; GoodJob's concurrency key discards the
    # duplicate while the failure-time schedule is queued.
    def arm_delayed_retry(run, attempt)
      AcceptanceAuditRetryJob.set(wait: AcceptanceAuditRetryJob.retry_delay(attempt)).perform_later(run.id, attempt)
    rescue StandardError => error
      Rails.logger.warn(
        message: "partial_closeout.audit_retry_arm_failed",
        issue_id: issue.id,
        agent_run_id: run.id,
        error_class: error.class.name,
        error: error.message
      )
    end

    def acceptance_audit_requests(source_revision)
      IssueContinuationRequest.where(issue:)
        .where("evidence->>'source_revision' = ?", source_revision)
        .where("evidence->>'continuation_mode' = ?", "acceptance_audit")
    end

    # Every attempt against one evidence generation counts against the budget,
    # including attempts made under an earlier approved intent.
    def audit_attempt_count(requests)
      AgentRun.where(continuation_request_id: requests.select(:id)).count
    end

    # Attempts for one evidence generation, newest first. The approved-intent
    # filter also admits legacy audits that recorded their intent on the run's
    # persisted assessment instead of the request evidence.
    def audit_runs(requests, intent_revision: nil)
      scope = AgentRun.where(continuation_request_id: requests.select(:id)).joins(:continuation_request)
      scope = scope.where(intent_revision_sql, revision: intent_revision) if intent_revision
      scope.order(id: :desc).limit(MAX_ATTEMPTS).to_a
    end

    def intent_revision_sql
      "issue_continuation_requests.evidence->>'intent_revision' = :revision OR " \
        "(issue_continuation_requests.evidence->>'intent_revision' IS NULL AND " \
        "(agent_runs.reconciliation #>> '{assessment,intent_revision}' = :revision OR " \
        "agent_runs.reconciliation->'assessment' IS NULL))"
    end

    def result(code) = Result.new(agent_run: nil, code:)
  end
end
