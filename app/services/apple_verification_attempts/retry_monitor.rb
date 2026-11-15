# frozen_string_literal: true

module AppleVerificationAttempts
  # Re-enqueues terminal attempts that failed for infrastructure reasons, up
  # to Config.max_retries and only while the queue has room, by claiming each
  # candidate through the shared retry mechanics. Idempotent: the unique
  # successor link (retry_of_attempt) means an attempt that already has a
  # retry is never claimed again, and sources that exhausted the retry budget
  # are excluded from the scan so recurring sweeps do not re-decide them.
  # @spec APPLE-ATTEMPT-010 AGENT-RETRY-016
  class RetryMonitor
    Result = Data.define(:retried, :scanned, :skipped)

    RETRYABLE_STATUSES = %w[unavailable timed_out failed].freeze

    def self.call
      new.call
    end

    def call
      retried = 0
      scanned = 0
      skipped = Hash.new(0)

      candidates.find_each do |attempt|
        break if Queue.full?

        scanned += 1
        outcome = retry_attempt.claim(source_id: attempt.id)
        if outcome.claimed?
          retried += 1
        elsif outcome.skipped?
          skipped[outcome.reason] += 1
        end
      end

      Result.new(retried: retried, scanned: scanned, skipped: skipped)
    end

    private

    def retry_attempt
      Retries::Attempt.new(policy: RetryPolicy.new, decision_point: RetryPolicy::DECISION_POINT)
    end

    def candidates
      AppleVerificationAttempt
        .where(status: RETRYABLE_STATUSES, failure_classification: FailureClassification::INFRASTRUCTURE)
        .where(retry_number: ...Config.max_retries)
        .where.missing(:retry_attempt)
    end
  end
end
