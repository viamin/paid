# frozen_string_literal: true

module AppleVerificationAttempts
  # Queues an immutable retry from a completed attempt by claiming through
  # the shared retry mechanics; translates refused claims back into the
  # operator-facing errors the controller surfaces.
  # @spec APPLE-VERIFY-006 AGENT-RETRY-016
  class Rerun
    OUTCOME_MESSAGES = {
      attempt_active: "only a completed attempt can be rerun",
      queue_full: "Apple verification queue is full",
      run_attempt_limit_reached: "Apple verification attempt limit reached for agent run",
      active_attempt_per_run: "Apple verification attempt limit reached for agent run"
    }.freeze
    DEFAULT_MESSAGE = "attempt failure is not retryable"

    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      return existing_retry if existing_retry

      result = retry_attempt.claim(source_id: @attempt.id)
      return result.successor if result.claimed?
      return @attempt.reload.retry_attempt if result.reason == :successor_already_claimed

      raise ArgumentError, OUTCOME_MESSAGES.fetch(result.reason, DEFAULT_MESSAGE)
    end

    private

    def retry_attempt
      Retries::Attempt.new(policy: RetryPolicy.new, decision_point: RetryPolicy::DECISION_POINT)
    end

    def existing_retry
      @attempt.retry_attempt
    end
  end
end
