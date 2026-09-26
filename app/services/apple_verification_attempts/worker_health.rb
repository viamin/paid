# frozen_string_literal: true

module AppleVerificationAttempts
  # Tracks Apple worker health and drives quarantine / return-to-service state.
  #
  # Quarantining stops scheduling: a quarantined profile reports `available?`
  # as false, so it is never handed a new attempt. Crossing the quarantine
  # threshold also terminates in-flight attempts through their canonical
  # completion path, which revokes their credential lanes.
  # @spec APPLE-ATTEMPT-015
  module WorkerHealth
    Result = Data.define(:quarantined, :consecutive_health_failures)

    class << self
      def record_failure!(profile:, reason:)
        profile.consecutive_health_failures = profile.consecutive_health_failures.to_i + 1
        profile.last_health_failure_at = Time.current

        if quarantine?(profile)
          profile.quarantined_at ||= Time.current
          # `quarantined?` requires `returned_to_service_at` to be clear, so a
          # profile that previously returned to service must drop that stamp
          # for the re-quarantine to take effect.
          profile.returned_to_service_at = nil
          profile.quarantine_reason = reason
        end

        profile.save!
        terminate_active_attempts!(profile) if profile.quarantined?
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

      def quarantine?(profile)
        profile.consecutive_health_failures >= Config.worker_health_failure_threshold
      end

      def terminate_active_attempts!(profile)
        profile.apple_verification_attempts.where(status: %w[provisioning running]).find_each do |attempt|
          Complete.call(
            attempt: attempt,
            outcome: "unavailable",
            failure_classification: "worker_infrastructure"
          )
        end
      end
    end
  end
end
