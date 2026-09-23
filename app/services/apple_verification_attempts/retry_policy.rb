# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-010
  # Decides whether a terminal Apple verification attempt may be retried.
  # Only safe infrastructure failures qualify — capacity exhaustion,
  # worker infrastructure outages, and timeouts. Deterministic project
  # failures and cancellations are not retried; pretending an
  # infrastructure outage was a code defect would burn the retry budget
  # and hide the real problem.
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
    end

    def initialize(attempt:, max_retries: DEFAULT_MAX_RETRIES)
      @attempt = attempt
      @max_retries = max_retries
    end

    def call
      return deny("not_terminal") unless @attempt.terminal?

      classification = FailureClassification.new(@attempt.failure_classification)
      return deny("not_infrastructure", classification.value) unless classification.infrastructure?
      return deny("cancelled", classification.value) if @attempt.status == "cancelled"
      return deny("max_retries_exceeded", classification.value) if retry_budget_exhausted?

      allow(classification.value)
    end

    private

    attr_reader :attempt

    def allow(classification)
      Decision.new(retryable: true, reason: "allowed", classification:)
    end

    def deny(reason, classification = nil)
      Decision.new(retryable: false, reason:, classification:)
    end

    def retry_budget_exhausted?
      attempt.retry_number >= max_retries
    end

    def max_retries
      @max_retries
    end
  end
end
