# frozen_string_literal: true

module AppleVerificationAttempts
  # Cancels an attempt that has not reached a terminal lifecycle state.
  # @spec APPLE-VERIFY-006
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-004
  class Cancel
    def self.call(...)
      new(...).call
    end

    def initialize(attempt:, lifecycle: nil, revocation: nil, outcome: "cancelled", clock: Time)
      @attempt = attempt
      @lifecycle = lifecycle
      @revocation = revocation
      @outcome = outcome
      @clock = clock
    end

    def call
      return @attempt if @attempt.terminal?

      return cancel_queued_attempt if @attempt.status == "queued"

      stop_vm
      @attempt.update!(status: outcome, failure_classification: "cancellation_or_timeout", finished_at: clock.current)
      revocation_service.call
      @attempt
    end

    private

    attr_reader :attempt, :lifecycle, :outcome, :clock

    def stop_vm
      return unless lifecycle

      lifecycle.stop(attempt:, request_id: "attempt:stop:#{attempt.id}")
    end

    def cancel_queued_attempt
      attempt.update!(status: "cancelled", failure_classification: "cancellation_or_timeout", finished_at: clock.current)
      attempt
    end

    def revocation_service
      @revocation ||= AppleVerification::Revocation::Enforce.new(attempt:)
    end
  end
end
