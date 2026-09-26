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

    # Best-effort: the stop request must never block the terminal-state
    # record or credential revocation. When the host service refuses or
    # cannot be reached, the structured warning lets reconciliation converge
    # the VM later (APPLE-ATTEMPT-014) while the timeout/cancellation
    # classification still lands.
    def stop_vm
      return unless lifecycle

      lifecycle.stop(attempt:, request_id: "attempt:stop:#{attempt.id}")
    rescue AppleVerification::HostService::AuthenticationError,
           AppleVerification::HostService::UnsupportedRequestError,
           AppleVerification::HostService::UnsafeRequestError,
           Faraday::Error => error
      Rails.logger.warn(
        message: "apple_verification.attempt_stop_failed",
        apple_verification_attempt_id: attempt.id,
        error_class: error.class.name,
        error: error.message
      )
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
