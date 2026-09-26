# frozen_string_literal: true

module AppleVerificationAttempts
  # Stops every active verification attempt when the host is no longer safe to
  # run them: the readiness payload reports sustained critical memory pressure
  # or exhausted host disk. Each affected attempt is completed as
  # `unavailable`/`worker_infrastructure`; the completion drives the real
  # host-side destroy through the lifecycle boundary first (retaining the VM
  # only when that destroy fails) so a host-safety violation actually relieves
  # the memory/disk pressure rather than leaving the VM running for the
  # failure-retention window. The status is rechecked under the attempt lock
  # before completing so a concurrent cancellation is not overwritten.
  # Idempotent: a completed attempt is terminal, so a rerun finds none.
  # @spec APPLE-ATTEMPT-002
  class HostSafetyMonitor
    ACTIVE_STATUSES = %w[provisioning running].freeze

    Result = Data.define(:terminated, :scanned)

    def self.call(capacity_sampler: HostCapacity.from_environment, lifecycle: AppleVerification::Lifecycle.from_environment, complete: Complete)
      new(capacity_sampler:, lifecycle:, complete:).call
    end

    def initialize(capacity_sampler:, lifecycle:, complete:)
      @capacity_sampler = capacity_sampler
      @lifecycle = lifecycle
      @complete = complete
    end

    def call
      return Result.new(terminated: 0, scanned: 0) unless capacity_sampler && lifecycle
      return Result.new(terminated: 0, scanned: 0) unless active_attempts?

      snapshot = capacity_sampler.host_safety_snapshot
      return Result.new(terminated: 0, scanned: 0) unless snapshot
      return Result.new(terminated: 0, scanned: 0) unless Admission.host_safety_violation?(capacity: snapshot.capacity, critical_memory_samples: snapshot.critical_memory_samples)

      terminated = 0
      scanned = 0

      AppleVerificationAttempt.where(status: ACTIVE_STATUSES).find_each do |attempt|
        scanned += 1
        terminated += 1 if terminate?(attempt)
      end

      Result.new(terminated:, scanned:)
    end

    private

    attr_reader :capacity_sampler, :lifecycle, :complete

    def active_attempts?
      AppleVerificationAttempt.where(status: ACTIVE_STATUSES).exists?
    end

    def terminate?(attempt)
      attempt.with_lock do
        attempt.reload
        terminate_locked_attempt?(attempt)
      end
    end

    def terminate_locked_attempt?(attempt)
      return false unless attempt.status.in?(ACTIVE_STATUSES)

      complete.call(
        attempt: attempt,
        outcome: "unavailable",
        failure_classification: "worker_infrastructure",
        lifecycle: lifecycle,
        terminate_vm: true
      )
      true
    end
  end
end
