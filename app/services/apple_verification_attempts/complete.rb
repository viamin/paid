# frozen_string_literal: true

module AppleVerificationAttempts
  # Finalizes an attempt after result ingestion, locking down before terminal state.
  # @spec APPLE-ATTEMPT-006
  class Complete
    def self.call(...)
      new(...).call
    end

    def initialize(attempt:, status:, failure_classification: nil, lifecycle: nil, revocation: nil, clock: Time)
      @attempt = attempt
      @status = status
      @failure_classification = failure_classification
      @lifecycle = lifecycle
      @revocation = revocation
      @clock = clock
    end

    def call
      return attempt if attempt.terminal?

      validate_result!
      destroy_successful_vm
      attempt.update!(status:, failure_classification:, finished_at: clock.current)
      revocation_service.call
      WorkerHealth.new(profile: attempt.apple_worker_profile).record_success if status == "succeeded"
      attempt
    rescue StandardError
      WorkerHealth.new(profile: attempt.apple_worker_profile).record_failure
      raise
    end

    private

    attr_reader :attempt, :status, :failure_classification, :lifecycle, :clock

    def validate_result!
      raise ArgumentError, "terminal status is required" unless AppleVerificationAttempt::TERMINAL_STATES.include?(status)
      return if status == "succeeded" && failure_classification.nil?
      return if FailureClassification.valid?(failure_classification)

      raise ArgumentError, "invalid Apple verification failure classification"
    end

    def destroy_successful_vm
      return unless status == "succeeded" && lifecycle

      lifecycle.destroy(attempt:, request_id: "attempt:destroy:#{attempt.id}")
    end

    def revocation_service
      @revocation ||= AppleVerification::Revocation::Enforce.new(attempt:)
    end
  end
end
