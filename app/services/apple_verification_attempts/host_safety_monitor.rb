# frozen_string_literal: true

module AppleVerificationAttempts
  # Stops every active verification attempt when the host is no longer safe to
  # run them: the readiness payload reports sustained critical memory pressure
  # or exhausted host disk. Each affected attempt is completed as
  # `unavailable`/`worker_infrastructure`, driving VM revocation through
  # `AppleVerificationAttempts::Complete`. Idempotent: a completed attempt is
  # terminal, so a rerun finds none.
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
        complete.call(attempt:, outcome: "unavailable", failure_classification: "worker_infrastructure")
        terminated += 1
      end

      Result.new(terminated:, scanned:)
    end

    private

    attr_reader :capacity_sampler, :lifecycle, :complete

    def active_attempts?
      AppleVerificationAttempt.where(status: ACTIVE_STATUSES).exists?
    end
  end
end
