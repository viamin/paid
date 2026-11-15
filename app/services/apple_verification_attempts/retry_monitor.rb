# frozen_string_literal: true

module AppleVerificationAttempts
  # Re-enqueues terminal attempts that failed for infrastructure reasons, up to
  # Config.max_retries and only while the queue has room. Idempotent: Rerun
  # links each queued retry back to its source via retry_of_attempt, so an
  # attempt that already has a retry is never scanned again.
  # @spec APPLE-ATTEMPT-010 AGENT-RETRY-018
  class RetryMonitor
    # `reasons` defaults to empty so count-only callers (e.g. the job) can
    # construct a result without refusal reasons.
    Result = Data.define(:retried, :scanned, :reasons) do
      def initialize(retried:, scanned:, reasons: [])
        super
      end
    end

    RETRYABLE_STATUSES = %w[unavailable timed_out failed].freeze

    def self.call
      new.call
    end

    def call
      # The classification prefilter keeps deterministic project failures out
      # of the scan entirely; RetryPolicy#assess still refuses them for direct
      # Rerun callers.
      candidates = AppleVerificationAttempt
        .where(status: RETRYABLE_STATUSES, failure_classification: FailureClassification::INFRASTRUCTURE)
        .where.missing(:retry_attempt)

      retried = 0
      scanned = 0
      reasons = []

      candidates.find_each do |attempt|
        if Queue.full?
          reasons << "Apple verification queue is full"
          break
        end

        scanned += 1
        result = retry_attempt.claim(attempt_id: attempt.id, retry_number: attempt.retry_number + 1)
        retried += 1 if result.claimed?
        reasons << result.reason unless result.claimed?
      end

      Result.new(retried:, scanned:, reasons: reasons.uniq.map(&:to_s))
    end

    private

    def retry_attempt
      RetryableAttempts::RetryAttempt.new(
        policy: RetryPolicy.new(attempt: nil),
        decision_point: "apple_verification_retry"
      )
    end
  end
end
