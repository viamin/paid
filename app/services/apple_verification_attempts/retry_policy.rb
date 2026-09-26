# frozen_string_literal: true

module AppleVerificationAttempts
  # Decides retry eligibility mechanically from the closed failure taxonomy.
  # @spec APPLE-ATTEMPT-010
  class RetryPolicy
    def self.retryable?(attempt, configuration: Configuration.new)
      attempt.terminal? && FailureClassification.infrastructure?(attempt.failure_classification) &&
        attempt.retry_number < configuration.maximum_retries
    end
  end
end
