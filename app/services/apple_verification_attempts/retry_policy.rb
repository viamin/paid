# frozen_string_literal: true

module AppleVerificationAttempts
  # Decides whether a failed Apple verification attempt is eligible for an
  # automatic retry. Infrastructure failures are retried up to Config.max_retries;
  # project failures are deterministic and never silently retried.
  # @spec APPLE-ATTEMPT-010
  class RetryPolicy
    Result = Data.define(:retryable, :reason)

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
  end
end
