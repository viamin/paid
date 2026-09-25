# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-006
  # Cancels and immediately finalizes an attempt that has not reached a
  # terminal lifecycle state, revoking its authority without waiting for the
  # maintenance sweep.
  # @spec APPLE-VERIFY-006
  class Cancel
    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      raise ArgumentError, "attempt is no longer active" unless @attempt.cancellable?

      @attempt.update!(
        status: "cancelled",
        failure_classification: "cancellation_or_timeout",
        finished_at: Time.current
      )
      AppleVerificationAttempts::Complete.call(attempt: @attempt)
      @attempt
    end
  end
end
