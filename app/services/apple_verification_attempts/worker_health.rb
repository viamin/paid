# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-015
  # Tracks repeated Apple worker health failures, quarantines a failing
  # worker, and refuses to schedule new attempts against it until an
  # operator runs the isolation smoke test and explicitly returns it to
  # service. Quarantine state lives on {AppleWorkerProfile} so an attempt
  # bound to a quarantined profile is rejected by
  # {AppleVerificationAttempts::Validate} before it can reserve capacity.
  class WorkerHealth
    DEFAULT_FAILURE_THRESHOLD = 3

    HealthCheck = Data.define(:profile, :consecutive_failures, :last_failure_at)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      profile:,
      failure_threshold: DEFAULT_FAILURE_THRESHOLD,
      attempt_scope: AppleVerificationAttempt,
      completion: Complete,
      lifecycle: AppleVerification::Lifecycle.from_environment,
      logger: Rails.logger,
      clock: Time
    )
      @profile = profile
      @failure_threshold = failure_threshold
      @attempt_scope = attempt_scope
      @completion = completion
      @lifecycle = lifecycle
      @logger = logger
      @clock = clock
    end

    # Probes the configured macOS worker and records its outcome. The
    # maintenance job invokes this path so host readiness failures reach the
    # quarantine policy in {#record}, rather than merely being logged.
    def call
      record(readiness_outcome) if @lifecycle
    end

    # Records a worker health outcome. When consecutive failures cross the
    # threshold the profile is quarantined: a +quarantined_at+ timestamp and
    # +quarantine_reason+ are persisted on the profile so
    # {AppleVerificationAttempts::Validate} and the lifecycle boundary can
    # reject attempts against it. A passing health check clears the failure
    # counter (but never clears a quarantine — only {#return_to_service}
    # does that).
    def record(outcome)
      profile = @profile
      now = current_time
      quarantined = profile.with_lock do
        profile.reload
        if outcome == :passed
          profile.update!(consecutive_health_failures: 0)
          next false
        end

        consecutive = (profile.consecutive_health_failures || 0) + 1
        attrs = {
          consecutive_health_failures: consecutive,
          last_health_failure_at: now
        }
        quarantining = consecutive >= @failure_threshold && !profile.quarantined?
        attrs.merge!(quarantine_attrs(consecutive, now)) if quarantining
        profile.update!(attrs)
        quarantining
      end
      quarantine_active_attempts(now) if quarantined
      HealthCheck.new(profile:, consecutive_failures: profile.consecutive_health_failures, last_failure_at: outcome == :passed ? nil : now)
    end

    # Returns the profile to service after an operator runs the isolation
    # smoke test. The smoke test must pass before any attempt is admitted
    # against this profile; the caller passes a smoke-test result object
    # that responds to +passed?+ — the operator command produces this
    # verdict via the macOS worker.
    def return_to_service(smoke_test_result:)
      raise ArgumentError, "isolation smoke test did not pass" unless smoke_test_result.respond_to?(:passed?) && smoke_test_result.passed?

      now = current_time
      @profile.with_lock do
        @profile.reload
        @profile.update!(
          quarantined_at: nil,
          quarantine_reason: nil,
          consecutive_health_failures: 0,
          last_health_failure_at: nil,
          returned_to_service_at: now,
          returned_to_service_by_id: smoke_test_result.operator_id
        )
      end
      @profile
    end

    private

    attr_reader :failure_threshold

    def readiness_outcome
      @lifecycle.readiness
      :passed
    rescue StandardError => error
      @logger.warn(
        message: "apple_verification_attempts.worker_health_check_failed",
        apple_worker_profile_id: @profile.id,
        error_class: error.class.name,
        error: error.message
      )
      :failed
    end

    def quarantine_active_attempts(now)
      active_attempts.find_each do |attempt|
        quarantined = attempt.with_lock do
          attempt.reload
          next false if attempt.terminal?

          attempt.update!(
            status: "unavailable",
            failure_classification: "worker_infrastructure",
            finished_at: now
          )
          true
        end
        @completion.call(attempt:) if quarantined
      end
    end

    def active_attempts
      @attempt_scope.where(apple_worker_profile_id: @profile.id, status: %w[provisioning running])
    end

    def current_time
      return @clock.current if @clock.respond_to?(:current)
      return @clock.now if @clock.respond_to?(:now)

      @clock
    end

    def quarantine_attrs(consecutive, now)
      {
        quarantined_at: now,
        quarantine_reason: "consecutive_health_failures=#{consecutive} threshold=#{@failure_threshold}"
      }
    end
  end
end
