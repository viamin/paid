# frozen_string_literal: true

module AppleVerificationAttempts
  # Persists host-health failure policy and smoke-test-gated recovery.
  # @spec APPLE-ATTEMPT-015
  class WorkerHealth
    def self.call(...)
      new(...).call
    end

    def initialize(profile:, configuration: Configuration.new, clock: Time)
      @profile = profile
      @configuration = configuration
      @clock = clock
    end

    def record_failure
      health.with_lock do
        failures = health.consecutive_failures + 1
        attrs = { consecutive_failures: failures }
        attrs.merge!(status: "quarantined", quarantined_at: clock.current) if failures >= configuration.health_failure_limit
        health.update!(attrs)
      end
    end

    def record_success
      health.with_lock { health.update!(consecutive_failures: 0) }
    end

    def record_isolation_smoke_test!
      health.with_lock { health.update!(isolation_smoke_tested_at: clock.current) }
    end

    def return_to_service!
      health.with_lock do
        raise ArgumentError, "a passing isolation smoke test is required" if health.isolation_smoke_tested_at.blank?

        health.update!(status: "healthy", consecutive_failures: 0, quarantined_at: nil)
      end
    end

    private

    attr_reader :profile, :configuration, :clock

    def health
      @health ||= AppleVerificationWorkerHealth.find_or_create_by!(apple_worker_profile: profile)
    end
  end
end
