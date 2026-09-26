# frozen_string_literal: true

module AppleVerificationAttempts
  # Tracks Apple worker health and drives quarantine / return-to-service state.
  #
  # Quarantining stops scheduling: a quarantined profile reports `available?`
  # as false, so it is never handed a new attempt. Revoking credentials for
  # in-flight attempts is the responsibility of
  # AppleVerification::Revocation::Enforce, not this service.
  # @spec APPLE-ATTEMPT-015
  module WorkerHealth
    Result = Data.define(:quarantined, :consecutive_health_failures)

    class << self
      def record_failure!(profile:, reason:)
        profile.consecutive_health_failures = profile.consecutive_health_failures.to_i + 1
        profile.last_health_failure_at = Time.current

        if profile.consecutive_health_failures >= Config.worker_health_failure_threshold
          profile.quarantined_at ||= Time.current
          # `quarantined?` requires `returned_to_service_at` to be clear, so a
          # profile that previously returned to service must drop that stamp
          # for the re-quarantine to take effect.
          profile.returned_to_service_at = nil
          profile.quarantine_reason = reason
        end

        profile.save!
        result_for(profile)
      end

      def record_success!(profile:)
        profile.consecutive_health_failures = 0
        profile.save!
        result_for(profile)
      end

      def return_to_service!(profile:, smoke_test_passed:)
        unless smoke_test_passed
          raise ArgumentError, "isolation smoke test must pass before returning worker to service"
        end

        profile.returned_to_service_at = Time.current
        profile.last_smoke_test_passed_at = Time.current
        profile.quarantined_at = nil
        profile.consecutive_health_failures = 0
        profile.save!

        Result.new(quarantined: false, consecutive_health_failures: 0)
      end

      def quarantined?(profile:)
        profile.quarantined?
      end

      private

      def result_for(profile)
        Result.new(
          quarantined: profile.quarantined?,
          consecutive_health_failures: profile.consecutive_health_failures
        )
      end
    end
  end
end
