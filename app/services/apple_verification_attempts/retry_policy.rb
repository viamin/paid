# frozen_string_literal: true

module AppleVerificationAttempts
  # Decides whether a failed Apple verification attempt is eligible for an
  # automatic retry. Infrastructure failures are retried up to Config.max_retries;
  # project failures are deterministic and never silently retried.
  # @spec APPLE-ATTEMPT-010 AGENT-RETRY-018
  class RetryPolicy
    Result = Data.define(:retryable, :reason)
    Assessment = Data.define(:eligible?, :reason, :attempt)

    RETRY_LINEAGE_CONSTRAINT = "idx_apple_attempts_one_retry_per_source"
    RETRY_ALREADY_CLAIMED = :retry_already_claimed

    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      return Result.new(false, "attempt is still active") unless @attempt.terminal?
      return Result.new(false, "no failure classification") if @attempt.failure_classification.nil?

      classification = @attempt.failure_classification
      if FailureClassification.infrastructure?(classification)
        return Result.new(true, "retryable infrastructure failure") if @attempt.retry_number < Config.max_retries

        return Result.new(false, "retry limit reached")
      end

      return Result.new(false, "deterministic project failure") if FailureClassification.project?(classification)

      Result.new(false, "no failure classification")
    end

    def assess(terminal_attempt = @attempt, retry_number: terminal_attempt.retry_number + 1)
      result = self.class.new(attempt: terminal_attempt).call
      return Assessment.new(false, result.reason, retry_number) unless result.retryable
      return Assessment.new(false, RETRY_ALREADY_CLAIMED, retry_number) if terminal_attempt.retry_attempt
      return Assessment.new(false, "Apple verification queue is full", retry_number) if Queue.full?
      return Assessment.new(false, "Apple verification attempt limit reached for agent run", retry_number) if agent_run_limit_reached?(terminal_attempt)

      Assessment.new(true, "retryable infrastructure failure", retry_number)
    end

    def attempt_class
      AppleVerificationAttempt
    end

    def build_successor!(attempt, retry_number)
      attempt.project.apple_verification_attempts.create!(retry_attributes(attempt, retry_number))
    end

    # Only a retry-lineage uniqueness violation means another claim already
    # owns this source's successor. Any other uniqueness violation — e.g. the
    # one-active-attempt-per-run admission race between two different terminal
    # attempts of the same agent run — must surface instead of being
    # misreported as an already-claimed retry.
    def duplicate_claim_conflict?(error)
      error.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == RETRY_LINEAGE_CONSTRAINT
    end

    def conflict_reason(_error)
      :already_claimed
    end

    # Apple attempts already persist their retry ledger through the unique
    # retry_of_attempt link. Recording a second AgentRun-oriented decision
    # would create conflicting identities for the same retry.
    def record_claim!(_attempt, successor:, decision_point:, retry_number:)
    end

    def record_skip!(_attempt, reason:, decision_point:, retry_number:)
    end

    private

    def agent_run_limit_reached?(attempt)
      attempt.agent_run && AppleVerificationAttempt.where(agent_run: attempt.agent_run).count >= Config.max_attempts_per_run
    end

    def retry_attributes(attempt, retry_number)
      {
        account: attempt.account,
        agent_run: attempt.agent_run,
        apple_verification_workflow_revision: attempt.apple_verification_workflow_revision,
        apple_worker_profile: attempt.apple_worker_profile,
        source_digest: attempt.source_digest,
        commit_sha: attempt.commit_sha,
        requested_capture: attempt.requested_capture,
        lifecycle_gate: attempt.lifecycle_gate,
        retry_number:,
        status: "queued",
        retry_of_attempt: attempt
      }
    end
  end
end
