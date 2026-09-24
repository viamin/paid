# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-005
  # Dispatches the next fair-share queued attempt. Validation failures become
  # classified terminal results; capacity refusals remain queued for
  # a later sweep. Until the guest-execution handoff can deliver source,
  # start verification, and record its result, admitted attempts also remain
  # queued so no VM is stranded in provisioning.
  class Schedule
    Result = Data.define(:attempt, :outcome, :reason)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(queue: Queue, validator: Validate, admission: Admission, clock: Time)
      @queue = queue
      @validator = validator
      @admission = admission
      @clock = clock
    end

    def call
      attempt = @queue.call.first&.attempt
      return Result.new(attempt: nil, outcome: "empty", reason: nil) unless attempt

      validation = @validator.call(attempt:)
      return reject(attempt, validation) unless validation.allowed?

      decision = @admission.call(project: attempt.project)
      return defer(attempt, decision.reason) unless decision.allowed?

      defer(attempt, "verification_execution_unavailable")
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
  end
end
