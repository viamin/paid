# frozen_string_literal: true

module AppleVerificationAttempts
  # Times out attempts stuck in a non-terminal `provisioning`/`running` state
  # beyond the configured attempt timeout. Each stale attempt is completed as
  # `timed_out`/`cancellation_or_timeout`, which drives VM revocation and
  # retention through `AppleVerificationAttempts::Complete`. Idempotent: a timed
  # out attempt is terminal, so a rerun finds none.
  # @spec APPLE-ATTEMPT-004
  class TimeoutMonitor
    ACTIVE_STATUSES = %w[provisioning running].freeze

    Result = Data.define(:timed_out, :scanned)

    def self.call(now: Time.current, complete: nil)
      new(now: now, complete: complete).call
    end

    def initialize(now:, complete:)
      @now = now
      @complete = complete || AppleVerificationAttempts::Complete
    end

    def call
      cutoff = @now - Config.attempt_timeout_minutes.minutes
      scanned = 0
      timed_out = 0

      AppleVerificationAttempt.where(status: ACTIVE_STATUSES).find_each do |attempt|
        scanned += 1
        next unless (attempt.started_at || attempt.created_at) <= cutoff

        @complete.call(
          attempt: attempt,
          outcome: "timed_out",
          failure_classification: "cancellation_or_timeout"
        )
        timed_out += 1
      end

      Result.new(timed_out: timed_out, scanned: scanned)
    end
  end
end
