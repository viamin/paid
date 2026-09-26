# frozen_string_literal: true

module AppleVerificationAttempts
  # Serializes admission and turns capacity refusal into an infrastructure result.
  # @spec APPLE-ATTEMPT-001
  # @spec APPLE-ATTEMPT-002
  # @spec APPLE-ATTEMPT-005
  class Admission
    ACTIVE_STATES = %w[provisioning running].freeze
    ADVISORY_LOCK_ID = 68_393_601

    Result = Data.define(:status, :attempt, :reason) do
      def admitted?
        status == :admitted
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(attempt:, capacity:, configuration: Configuration.new, clock: Time)
      @attempt = attempt
      @capacity = capacity
      @configuration = configuration
      @clock = clock
    end

    def call
      AppleVerificationAttempt.transaction do
        lock_scheduler!
        attempt.lock!
        return Result.new(status: :unchanged, attempt:, reason: nil) unless attempt.status == "queued"
        return Result.new(status: :unchanged, attempt:, reason: "Apple verification workers are disabled") unless enabled?
        return validation_failure! unless validation.valid?

        reason = refusal_reason
        return refuse!(reason) if reason

        attempt.update!(status: "provisioning", admission_reserved_at: clock.current, started_at: attempt.started_at || clock.current)
        Result.new(status: :admitted, attempt:, reason: nil)
      end
    end

    private

    attr_reader :attempt, :capacity, :configuration, :clock

    def lock_scheduler!
      quoted_id = AppleVerificationAttempt.connection.quote(ADVISORY_LOCK_ID)
      AppleVerificationAttempt.connection.execute("SELECT pg_advisory_xact_lock(#{quoted_id})")
    end

    def refusal_reason
      return "worker is quarantined" if worker_health.quarantined?
      return "active VM limit reached" if active_attempts >= configuration.active_vm_limit
      return "critical memory pressure" if capacity.critical_memory_pressure
      return "insufficient host disk" if capacity.free_host_disk_bytes < configuration.minimum_host_disk_bytes
      return "insufficient host memory" if capacity.free_memory_fraction < configuration.minimum_memory_free_fraction
      "insufficient guest disk" if capacity.free_guest_disk_bytes < configuration.minimum_guest_disk_bytes
    end

    def enabled?
      FeatureFlags.enabled?(:apple_verification_workers, project: attempt.project)
    end

    def validation
      @validation ||= Validate.call(attempt:)
    end

    def validation_failure!
      attempt.update!(status: "failed", failure_classification: validation.failure_classification, finished_at: clock.current)
      Result.new(status: :invalid, attempt:, reason: validation.reason)
    end

    def active_attempts
      AppleVerificationAttempt.where(status: ACTIVE_STATES).count
    end

    def worker_health
      AppleVerificationWorkerHealth.find_or_create_by!(apple_worker_profile: attempt.apple_worker_profile)
    end

    def refuse!(reason)
      attempt.update!(status: "unavailable", failure_classification: "capacity_or_quota", finished_at: clock.current)
      Result.new(status: :unavailable, attempt:, reason:)
    end
  end
end
