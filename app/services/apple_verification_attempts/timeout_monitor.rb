# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-004
  # Marks Apple verification attempts whose runtime has exceeded the
  # configured limit (default 45 minutes) as +timed_out+ and records the
  # infrastructure-only failure classification. A timeout is an
  # infrastructure result, never a code failure — the RDR requires the
  # distinction so retries don't paper over an actual host or worker
  # outage by treating it as a project defect.
  class TimeoutMonitor
    DEFAULT_TIMEOUT_MINUTES = 45
    BATCH_SIZE = 100

    Result = Data.define(:scanned, :timed_out)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      attempt_scope: AppleVerificationAttempt,
      timeout_minutes: DEFAULT_TIMEOUT_MINUTES,
      clock: Time,
      logger: Rails.logger,
      completion: Complete,
      batch_size: BATCH_SIZE
    )
      @attempt_scope = attempt_scope
      @timeout_minutes = timeout_minutes
      @clock = clock
      @logger = logger
      @completion = completion
      @batch_size = batch_size
    end

    def call
      now = current_time
      threshold = now - timeout_seconds.seconds
      candidates = expired_attempts(threshold)
      scanned = candidates.count
      timed_out_ids = []

      candidates.find_each(batch_size: @batch_size) do |attempt|
        timed_out = attempt.with_lock do
          attempt.reload
          next false if attempt.terminal?

          attempt.update!(
            status: "timed_out",
            failure_classification: "cancellation_or_timeout",
            finished_at: now
          )
          log_timed_out(attempt)
          true
        end
        next unless timed_out

        @completion.call(attempt: attempt)
        timed_out_ids << attempt.id
      end

      Result.new(scanned: scanned, timed_out: timed_out_ids)
    end

    # Returns the deadline a fresh attempt with +started_at: now+ would
    # inherit. Used by the executor to stamp +started_at+ consistently with
    # the timeout monitor's threshold.
    def deadline_for(started_at)
      started_at + timeout_seconds.seconds
    end

    attr_reader :timeout_minutes

    def self.timeout_minutes_from(timeout_minutes: nil)
      return timeout_minutes if timeout_minutes.present?

      Integer(ENV.fetch("APPLE_VERIFICATION_TIMEOUT_MINUTES", DEFAULT_TIMEOUT_MINUTES.to_s))
    end

    private

    attr_reader :attempt_scope

    def current_time
      return @clock.current if @clock.respond_to?(:current)
      return @clock.now if @clock.respond_to?(:now)

      @clock
    end

    def expired_attempts(threshold)
      attempt_scope.timed_out_candidates(threshold)
    end

    def timeout_seconds
      @timeout_minutes * 60
    end

    def log_timed_out(attempt)
      @logger.info(
        message: "apple_verification_attempts.timeout_monitor_marked",
        apple_verification_attempt_id: attempt.id,
        account_id: attempt.account_id,
        project_id: attempt.project_id,
        timeout_minutes: @timeout_minutes,
        failure_classification: "cancellation_or_timeout"
      )
    end
  end
end
