# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-005
  # Dispatches the next fair-share queued attempt. Validation failures become
  # classified terminal results; capacity refusals remain queued for
  # a later sweep. A lifecycle call happens only after both checks pass.
  class Schedule
    Result = Data.define(:attempt, :outcome, :reason)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(queue: Queue, validator: Validate, admission: Admission,
      lifecycle: AppleVerification::Lifecycle.from_environment, clock: Time)
      @queue = queue
      @validator = validator
      @admission = admission
      @lifecycle = lifecycle
      @clock = clock
    end

    def call
      attempt = @queue.call.first&.attempt
      return Result.new(attempt: nil, outcome: "empty", reason: nil) unless attempt

      validation = @validator.call(attempt:)
      return reject(attempt, validation) unless validation.allowed?

      decision = @admission.call(project: attempt.project)
      return defer(attempt, decision.reason) unless decision.allowed?
      return defer(attempt, "lifecycle_unavailable") unless @lifecycle

      provision(attempt)
    end

    private

    def reject(attempt, validation)
      attempt.with_lock do
        return defer(attempt, "attempt_no_longer_queued") unless attempt.queued?

        attempt.update!(status: "failed", failure_classification: validation.classification, finished_at: @clock.current)
      end
      Result.new(attempt:, outcome: "rejected", reason: validation.reason)
    end

    def defer(attempt, reason)
      Result.new(attempt:, outcome: "deferred", reason:)
    end

    def provision(attempt)
      attempt.with_lock { attempt.update!(status: "provisioning", started_at: @clock.current) if attempt.queued? }
      return defer(attempt, "attempt_no_longer_queued") unless attempt.provisioning?

      @lifecycle.provision(
        agent_run: attempt.agent_run,
        image_id: attempt.apple_worker_profile.image_digest,
        profile_id: attempt.apple_worker_profile.name,
        request_id: "apple_verification_attempt:#{attempt.id}",
        apple_verification_attempt: attempt
      )
      Result.new(attempt:, outcome: "provisioning", reason: nil)
    end
  end
end
