# frozen_string_literal: true

module AppleVerificationAttempts
  # The canonical terminal transition for an Apple verification attempt.
  #
  # Revokes the attempt's credentials and network authority, then drives VM
  # destruction on success (via the lifecycle boundary) before persisting the
  # terminal +outcome+ (and optional +failure_classification+) via
  # {AppleVerification::Revocation::Enforce}. A
  # destroy failure on the immediate-success path is logged but tolerated so
  # it cannot corrupt an otherwise-valid terminal transition — the sweep and
  # retention windows still own the VM afterwards.
  #
  # @spec APPLE-ATTEMPT-006
  class Complete
    Result = Data.define(:outcome, :failure_classification, :retained_until)

    def self.call(attempt:, outcome:, failure_classification: nil, lifecycle: nil, revocation: nil)
      new(attempt:, outcome:, failure_classification:, lifecycle:, revocation:).call
    end

    def initialize(attempt:, outcome:, failure_classification: nil, lifecycle: nil, revocation: nil)
      @attempt = attempt
      @outcome = outcome
      @failure_classification = failure_classification
      @lifecycle = lifecycle
      @revocation = revocation
    end

    def call
      raise ArgumentError, "outcome must be a terminal state" unless outcome.in?(AppleVerificationAttempt::TERMINAL_STATES)

      revocation_result = revocation.call
      destroy_vm if outcome == "succeeded"
      attempt.update!(terminal_attributes)

      Result.new(
        outcome: outcome,
        failure_classification: attempt.failure_classification,
        retained_until: revocation_result.retained_until
      )
    end

    private

    attr_reader :attempt, :outcome, :failure_classification, :lifecycle

    def revocation
      @revocation || AppleVerification::Revocation::Enforce.new(
        attempt: attempt,
        outcome: outcome,
        failed_vm_retention_hours: Config.failed_vm_retention_hours
      )
    end

    def terminal_attributes
      {
        status: outcome,
        finished_at: Time.current,
        failure_classification: failure_classification.presence || attempt.failure_classification
      }
    end

    def destroy_vm
      lifecycle&.destroy(attempt: attempt, request_id: "complete:#{attempt.id}")
    rescue StandardError => e
      Rails.logger.warn(
        message: "apple_verification.complete.destroy_failed",
        attempt_id: attempt.id,
        error: e.message
      )
    end
  end
end
