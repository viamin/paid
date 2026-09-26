# frozen_string_literal: true

module AppleVerificationAttempts
  # The canonical terminal transition for an Apple verification attempt.
  #
  # On success — and, when +terminate_vm+ is set, on any terminal outcome
  # (e.g. a host-safety termination that must relieve memory/disk pressure
  # immediately) — drives VM destruction through the lifecycle boundary
  # first, then revokes the attempt's credentials and network authority via
  # {AppleVerification::Revocation::Enforce} — which records the `destroyed`
  # audit event only when the lifecycle destroy actually happened — before
  # persisting the terminal +outcome+ (and optional +failure_classification+).
  # When the immediate destroy cannot be backed by a real host action (no
  # lifecycle configured, destroy error, or a no-op), revocation falls back to
  # the failure retention window and persists +container_retained_until+ so
  # {AppleVerification::Bundles::RetentionSweep} retries the destroy. A
  # destroy error is logged but tolerated so it cannot corrupt an
  # otherwise-valid terminal transition.
  #
  # @spec APPLE-ATTEMPT-006
  class Complete
    Result = Data.define(:outcome, :failure_classification, :retained_until)

    def self.call(attempt:, outcome:, failure_classification: nil, lifecycle: AppleVerification::Lifecycle.from_environment, revocation: nil, terminate_vm: false)
      new(attempt:, outcome:, failure_classification:, lifecycle:, revocation:, terminate_vm:).call
    end

    def initialize(attempt:, outcome:, failure_classification: nil, lifecycle: AppleVerification::Lifecycle.from_environment, revocation: nil, terminate_vm: false)
      @attempt = attempt
      @outcome = outcome
      @failure_classification = failure_classification
      @lifecycle = lifecycle
      @revocation = revocation
      @terminate_vm = terminate_vm
    end

    def call
      raise ArgumentError, "outcome must be a terminal state" unless outcome.in?(AppleVerificationAttempt::TERMINAL_STATES)

      destroy_result = destroy_vm if terminate_vm_requested?
      revocation_result = revocation(destroy_result).call
      attempt.update!(terminal_attributes)

      Result.new(
        outcome: outcome,
        failure_classification: attempt.failure_classification,
        retained_until: revocation_result.retained_until
      )
    end

    private

    attr_reader :attempt, :outcome, :failure_classification, :lifecycle

    def terminate_vm_requested?
      outcome == "succeeded" || @terminate_vm
    end

    def revocation(destroy_result)
      @revocation || AppleVerification::Revocation::Enforce.new(
        attempt: attempt,
        outcome: outcome,
        lifecycle: lifecycle,
        failed_vm_retention_hours: Config.failed_vm_retention_hours,
        vm_destroy_result: destroy_result
      )
    end

    def terminal_attributes
      {
        status: outcome,
        finished_at: Time.current,
        failure_classification: failure_classification.presence || attempt.failure_classification
      }
    end

    # Returns the lifecycle destroy outcome (`:destroyed`, `:noop`, nil when
    # no lifecycle is configured, `:destroy_failed` on error) so the
    # revocation service only records a `destroyed` audit event for a destroy
    # that actually happened.
    def destroy_vm
      lifecycle&.destroy(attempt: attempt, request_id: "complete:#{attempt.id}")
    rescue StandardError => e
      Rails.logger.warn(
        message: "apple_verification.complete.destroy_failed",
        attempt_id: attempt.id,
        error_class: e.class.name,
        error: e.message
      )
      :destroy_failed
    end
  end
end
