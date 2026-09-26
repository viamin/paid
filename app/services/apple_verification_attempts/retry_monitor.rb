# frozen_string_literal: true

module AppleVerificationAttempts
  # Re-enqueues terminal attempts that failed for infrastructure reasons, up to
  # Config.max_retries and only while the queue has room. Idempotent: Rerun
  # links each queued retry back to its source via retry_of_attempt, so an
  # attempt that already has a retry is never scanned again.
  # @spec APPLE-ATTEMPT-010
  class RetryMonitor
    Result = Data.define(:retried, :scanned)

    RETRYABLE_STATUSES = %w[unavailable timed_out failed].freeze

    def self.call
      new.call
    end

    def call
      candidates = AppleVerificationAttempt
        .where(status: RETRYABLE_STATUSES, failure_classification: FailureClassification::INFRASTRUCTURE)
        .where.missing(:retry_attempt)

      retried = 0
      scanned = 0

      candidates.find_each do |attempt|
        break if Queue.full?

        scanned += 1
        next unless RetryPolicy.call(attempt: attempt).retryable

        Rerun.call(attempt: attempt)
        retried += 1
      end

      Result.new(retried: retried, scanned: scanned)
    end
  end
end
