# frozen_string_literal: true

module AppleVerificationAttempts
  # Queues an immutable retry from a completed attempt.
  # @spec APPLE-VERIFY-006 AGENT-RETRY-018
  class Rerun
    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      raise ArgumentError, "only a completed attempt can be rerun" unless @attempt.terminal?
      result = retry_attempt.claim(attempt_id: @attempt.id, retry_number: @attempt.retry_number + 1)
      return result.successor if result.claimed?
      return existing_retry if already_claimed?(result) && existing_retry

      raise ArgumentError, result.reason
    end

    private

    def existing_retry
      @attempt.retry_attempt
    end

    def already_claimed?(result)
      result.reason.in?([ RetryPolicy::RETRY_ALREADY_CLAIMED, :already_claimed ])
    end

    def retry_attempt
      RetryableAttempts::RetryAttempt.new(
        policy: RetryPolicy.new(attempt: @attempt),
        decision_point: "apple_verification_retry"
      )
    end
  end
end
