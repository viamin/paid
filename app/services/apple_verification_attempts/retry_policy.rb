# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-010
  # Decides whether a terminal Apple verification attempt may be retried.
  #
  # The automatic retry policy — the `.call` entry point — permits only safe
  # infrastructure failures: capacity exhaustion, worker infrastructure
  # outages, and timeouts. Deterministic project failures and cancellations
  # are not silently retried; pretending an infrastructure outage was a code
  # defect would burn the retry budget and hide the real problem. An attempt
  # with no failure classification (legacy rows predating the taxonomy, and
  # succeeded attempts) stays retryable because an unknown classification is
  # not a deterministic project failure and APPLE-VERIFY-006 preserves
  # administrator rerun control.
  #
  # The explicit-rerun policy — the `.explicit` entry point — backs an
  # administrator-initiated rerun, which is never a silent retry. It permits
  # deterministic project failures because the administrator chose to rerun
  # them deliberately; it still refuses cancelled attempts and attempts
  # beyond the retry budget.
  class RetryPolicy
    DEFAULT_MAX_RETRIES = 3

    Decision = Data.define(:retryable, :reason, :classification) do
      def retryable?
        retryable
      end
    end

    REASONS = %w[
      allowed
      not_terminal
      not_infrastructure
      cancelled
      max_retries_exceeded
      max_runtime_exceeded
    ].freeze

    class << self
      def call(...)
        new(...).call
      end

      def explicit(attempt:, max_retries: DEFAULT_MAX_RETRIES)
        new(attempt:, max_retries:, allow_deterministic_failures: true).call
      end
    end

    def initialize(attempt:, max_retries: DEFAULT_MAX_RETRIES, allow_deterministic_failures: false)
      @attempt = attempt
      @max_retries = max_retries
      @allow_deterministic_failures = allow_deterministic_failures
    end

    def call
      return deny("not_terminal") unless @attempt.terminal?

      classification = FailureClassification.coerce(@attempt.failure_classification)
      return deny("not_infrastructure", classification.value) if deny_deterministic_failure?(classification)
      return deny("cancelled", classification.value) if @attempt.status == "cancelled"
      return deny("max_retries_exceeded", classification.value) if retry_budget_exhausted?

      allow(classification.value)
    end

    private

    attr_reader :attempt, :max_retries

    def deny_deterministic_failure?(classification)
      return false if @allow_deterministic_failures

      classification.value.present? && !classification.infrastructure?
    end

    def allow(classification)
      Decision.new(retryable: true, reason: "allowed", classification:)
    end

    def deny(reason, classification = nil)
      Decision.new(retryable: false, reason:, classification:)
    end

    def retry_budget_exhausted?
      attempt.retry_number >= max_retries
    end
  end
end
