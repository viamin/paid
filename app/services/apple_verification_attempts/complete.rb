# frozen_string_literal: true

module AppleVerificationAttempts
  # Finalizes an attempt after result ingestion, locking down before terminal state.
  # @spec APPLE-ATTEMPT-006
  class Complete
    def self.call(...)
      new(...).call
    end

    def initialize(attempt:, status:, failure_classification: nil, lifecycle: nil, revocation: nil, configuration: Configuration.new, clock: Time)
      @attempt = attempt
      @status = status
      @failure_classification = failure_classification
      @lifecycle = lifecycle
      @revocation = revocation
      @configuration = configuration
      @clock = clock
    end

    def call
      return attempt if attempt.terminal?

      validate_result!
      lock_down_vm
      attempt.update!(status:, failure_classification:, finished_at: clock.current)
      revocation_service.call
      WorkerHealth.new(profile: attempt.apple_worker_profile).record_success if status == "succeeded"
      attempt
    rescue StandardError
      WorkerHealth.new(profile: attempt.apple_worker_profile).record_failure
      raise
    end

    private

    attr_reader :attempt, :status, :failure_classification, :configuration, :clock

    def validate_result!
      raise ArgumentError, "terminal status is required" unless AppleVerificationAttempt::TERMINAL_STATES.include?(status)
      return if status == "succeeded" && failure_classification.nil?
      return if FailureClassification.valid?(failure_classification)

      raise ArgumentError, "invalid Apple verification failure classification"
    end

    # Best-effort: a refused or unreachable destroy must never block the
    # terminal-state record or credential revocation. The structured warning
    # lets reconciliation converge the VM later (APPLE-ATTEMPT-014).
    def lock_down_vm
      return unless lifecycle

      status == "succeeded" ? destroy_vm : stop_vm
    rescue AppleVerification::HostService::AuthenticationError,
           AppleVerification::HostService::UnsupportedRequestError,
           AppleVerification::HostService::UnsafeRequestError,
           Faraday::Error => error
      Rails.logger.warn(
        message: "apple_verification.attempt_destroy_failed",
        apple_verification_attempt_id: attempt.id,
        error_class: error.class.name,
        error: error.message
      )
    end

    def destroy_vm
      lifecycle.destroy(attempt:, request_id: "attempt:destroy:#{attempt.id}")
    end

    def stop_vm
      lifecycle.stop(attempt:, request_id: "attempt:stop:#{attempt.id}")
    end

    def lifecycle
      @lifecycle ||= AppleVerification::Lifecycle.from_environment
    end

    def revocation_service
      @revocation ||= AppleVerification::Revocation::Enforce.new(
        attempt:,
        failed_vm_retention: configuration.failed_vm_retention
      )
    end
  end
end
