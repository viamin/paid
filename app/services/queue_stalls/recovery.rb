# frozen_string_literal: true

module QueueStalls
  # Recovers one detected stall by invoking the existing recovery services
  # within their own delegated authority (#4619).
  #
  # The recovery never clears a hold, closes an issue, changes a paid_state,
  # or overrides a rollout/approval policy: it delegates to
  # `Issues::EnqueueEligible`, `FeatureIntents::ReleaseIssue` and the
  # agent_harness closeout reconciler, and records what happened.
  #
  # Repeated assessment of an unchanged state is a no-op: the durable
  # assessment carries the state digest, so the same state is never recovered
  # twice, and a failed attempt is retried only inside a bounded window.
  # @spec QUEUE-DIAG-004 @spec QUEUE-DIAG-005 @spec QUEUE-DIAG-006
  # @spec QUEUE-DIAG-007 @spec QUEUE-DIAG-008
  class Recovery
    Outcome = Struct.new(:issue_id, :reason_code, :outcome, :message, keyword_init: true)

    # How long an unchanged state must persist before it counts as a stall.
    STALE_AGE = 1.hour
    # Backoff before a failed recovery is retried for the same state.
    RETRY_WINDOW = 15.minutes
    # Attempts allowed for one state before the issue is left for a human.
    MAX_ATTEMPTS = 3

    def self.call(...)
      new(...).call
    end

    def initialize(account:, candidate:, state_digest:, blockers: [], closeout_evidence: nil)
      @account = account
      @candidate = candidate
      @state_digest = state_digest
      @blockers = blockers
      @closeout_evidence = closeout_evidence
    end

    def call
      existing = assessment

      if existing.nil?
        return perform_recovery if immediately_actionable?

        return observe
      end

      return skip("attempt cap reached for this state") if existing.attempt_count >= MAX_ATTEMPTS
      return skip("state has not been unchanged long enough") unless stale_enough?(existing)
      return skip("this state was already assessed") if existing.outcome.in?(%w[recovered blocked])
      return skip("retry window has not elapsed") if existing.outcome == "failed" && !retry_window_elapsed?(existing)

      perform_recovery
    end

    private

    attr_reader :account, :candidate, :state_digest, :blockers, :closeout_evidence

    def issue_id = candidate.issue_id

    def reason_code = candidate.reason_code

    def issue
      @issue ||= Issue.find_by(id: issue_id)
    end

    def project
      @project ||= issue&.project
    end

    # Seeding an eligible candidate is the ordinary admission path, so it is
    # attempted as soon as the candidate is observed. The hold reassessment
    # and the semantic closeout reconciliation are only worth their cost once
    # the state has been unchanged for a while.
    def immediately_actionable?
      reason_code == "unseeded_runnable"
    end

    def assessment
      @assessment ||= QueueStallAssessment.find_by(
        account_id: account.id,
        issue_id: issue_id,
        reason_code: reason_code,
        state_digest: state_digest
      )
    end

    def stale_enough?(existing)
      return true if reason_code == "unseeded_runnable"

      # `created_at` is when this state was first observed; the state has been
      # unchanged for as long as that record has existed.
      existing.created_at <= STALE_AGE.ago
    end

    def retry_window_elapsed?(existing)
      existing.assessed_at <= RETRY_WINDOW.ago
    end

    def observe
      record("observed", "Observed an unchanged state; it becomes a stall once it persists.")
    end

    def skip(message)
      Outcome.new(issue_id:, reason_code:, outcome: "skipped", message:)
    end

    def perform_recovery
      return record("blocked", "The issue no longer exists.") if issue.nil?

      case reason_code
      when "unseeded_runnable" then recover_unseeded_runnable
      when "stale_planning_hold" then recover_stale_planning_hold
      when "unresolved_delivery" then recover_unresolved_delivery
      else record("skipped", "Unknown stall reason; no recovery applies.")
      end
    rescue StandardError => error
      Rails.logger.error(
        message: "queue_stalls.recovery_failed",
        reason_code:,
        issue_id:,
        error_class: error.class.name,
        error: error.message
      )
      record("failed", "#{error.class}: #{error.message}")
    end

    # @spec QUEUE-DIAG-004
    def recover_unseeded_runnable
      run = Issues::EnqueueEligible.call(issue, project:)
      return record("blocked", "The issue was not admitted for automatic work.") if run.nil?

      record("recovered", "Queued agent run #{run.id} for the eligible candidate.")
    end

    # @spec QUEUE-DIAG-004
    def recover_stale_planning_hold
      result = FeatureIntents::ReleaseIssue.call(issue:)
      return record("recovered", "The planning hold was released.") if result.released?

      record("blocked", result.reason.presence || "The planning hold is still held.")
    end

    # The semantic assessment runs through the existing agent_harness
    # recovery path. This service never calls an LLM itself.
    # @spec QUEUE-DIAG-007
    def recover_unresolved_delivery
      run = latest_pr_run
      return record("skipped", "No pull-request-producing run is recorded for this issue.") if run.nil?

      result = PartialCloseouts::ReconcileLegacy.reconcile_run(run)
      case result
      when :reconciled then record("recovered", "The delivered work was reconciled through the closeout recovery path.")
      when :awaiting_operator then record("blocked", "The closeout recovery is waiting for an operator decision.")
      when :retryable_failure then record("failed", "The closeout recovery failed and can be retried.")
      else record("skipped", "The closeout recovery had nothing to do for this delivery.")
      end
    end

    def latest_pr_run
      issue.agent_runs.where(goal: "create_pr").where.not(pull_request_number: nil).order(id: :desc).first
    end

    def record(outcome, message)
      persist_assessment(outcome, message)
      Outcome.new(issue_id:, reason_code:, outcome:, message:)
    end

    def persist_assessment(outcome, detail)
      existing = assessment
      if existing
        existing.update!(
          outcome:,
          attempt_count: existing.attempt_count + 1,
          assessed_at: Time.current,
          detail: detail
        )
      else
        QueueStallAssessment.create!(
          account:,
          issue:,
          reason_code:,
          state_digest:,
          outcome:,
          attempt_count: 1,
          detail: detail,
          assessed_at: Time.current
        )
      end
    end
  end
end
