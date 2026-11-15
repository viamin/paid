# frozen_string_literal: true

module AppleVerificationAttempts
  # Decides whether a failed Apple verification attempt gets another attempt
  # and owns the Apple-specific admission rules, successor shape, and decision
  # recording for the shared retry mechanics (Retries::Attempt).
  # Infrastructure failures are retried up to Config.max_retries; project
  # failures are deterministic and never silently retried.
  # @spec APPLE-ATTEMPT-010 APPLE-VERIFY-006 AGENT-RETRY-015 AGENT-RETRY-016
  class RetryPolicy
    DECISION_POINT = "apple_verification_auto_retry"
    ONE_RETRY_PER_SOURCE_CONSTRAINT = "idx_apple_attempts_one_retry_per_source"
    ONE_ACTIVE_PER_RUN_CONSTRAINT = "idx_apple_attempts_one_active_per_run"

    def assess(attempt, attempt_number: next_attempt_number(attempt))
      return Retries::Assessment.new(false, :attempt_active, attempt_number) unless attempt.terminal?
      return Retries::Assessment.new(false, :unclassified_failure, attempt_number) if attempt.failure_classification.nil?

      classification = attempt.failure_classification
      if FailureClassification.infrastructure?(classification)
        return Retries::Assessment.new(false, :retry_limit_reached, attempt_number) if attempt.retry_number >= Config.max_retries
        return Retries::Assessment.new(false, :successor_already_claimed, attempt_number) if attempt.retry_attempt.present?

        return Retries::Assessment.new(true, :retryable_infrastructure_failure, attempt_number)
      end

      return Retries::Assessment.new(false, :deterministic_project_failure, attempt_number) if FailureClassification.project?(classification)

      Retries::Assessment.new(false, :unclassified_failure, attempt_number)
    end

    def next_attempt_number(attempt)
      attempt.retry_number + 1
    end

    def maximum_attempts
      Config.max_retries
    end

    def claim_transaction(&block)
      AppleVerificationAttempt.transaction(&block)
    end

    def lock_source(id)
      AppleVerificationAttempt.lock.find_by(id: id)
    end

    def find_source(id)
      AppleVerificationAttempt.find_by(id: id)
    end

    # Admission rechecks evaluated under the claim lock. The queue-capacity
    # and per-agent-run refusals share the claim transaction so a refusal
    # leaves no phantom successor behind.
    def admission_reason(attempt)
      return :queue_full if Queue.full?
      return :run_attempt_limit_reached if agent_run_limit_reached?(attempt)

      nil
    end

    def build_successor!(attempt, _attempt_number)
      attempt.project.apple_verification_attempts.create_or_find_by!(retry_of_attempt: attempt) do |rerun_attempt|
        rerun_attempt.assign_attributes(retry_attributes(attempt))
      end
    end

    def duplicate_claim_conflict?(error)
      conflict_reason(error).present?
    end

    def duplicate_claim_conflict_reason(error)
      conflict_reason(error)
    end

    # @spec AGENT-RETRY-004
    def record_claim!(attempt, successor:, decision_point:, signals:)
      OrchestrationDecision.record!(
        project: attempt.project,
        agent_run: attempt.agent_run,
        decision_point: decision_point,
        action: decision_point,
        status: "applied",
        context: { apple_verification_attempt_id: attempt.id },
        signals: signals,
        result: { new_apple_verification_attempt_id: successor.id, reason: "retry_claimed" }
      )
    end

    # @spec AGENT-RETRY-004
    def record_skip!(attempt, reason:, decision_point:, signals:)
      OrchestrationDecision.record(
        project: attempt.project,
        agent_run: attempt.agent_run,
        decision_point: decision_point,
        action: decision_point,
        status: "noop",
        context: { apple_verification_attempt_id: attempt.id },
        signals: signals.merge(reason: reason.to_s),
        result: { reason: reason.to_s }
      )
    end

    private

    def conflict_reason(error)
      case error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
      when ONE_RETRY_PER_SOURCE_CONSTRAINT then :successor_already_claimed
      when ONE_ACTIVE_PER_RUN_CONSTRAINT then :active_attempt_per_run
      end
    end

    def agent_run_limit_reached?(attempt)
      attempt.agent_run && AppleVerificationAttempt.where(agent_run: attempt.agent_run).count >= Config.max_attempts_per_run
    end

    def retry_attributes(attempt)
      {
        account: attempt.account,
        agent_run: attempt.agent_run,
        apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
        apple_worker_profile: attempt.apple_worker_profile,
        source_digest: attempt.source_digest,
        commit_sha: attempt.commit_sha,
        requested_capture: attempt.requested_capture,
        lifecycle_gate: attempt.lifecycle_gate,
        retry_number: attempt.retry_number + 1,
        status: "queued",
        retry_of_attempt: attempt
      }
    end
  end
end
