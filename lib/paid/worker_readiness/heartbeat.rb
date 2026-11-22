# frozen_string_literal: true

module Paid
  module WorkerReadiness
    # Publishes the running worker process's readiness identity for its Temporal
    # roles on a fixed interval, so another container's trusted worker-adoption
    # measurement can observe this process through the shared application
    # database instead of a readiness file or PID probe that cannot cross
    # container boundaries (config/deploy.yml runs each role as an independent
    # container with no shared volume). The heartbeat refreshes for the whole
    # process lifetime: a static boot receipt would make every worker older
    # than the freshness window look dead, while a live worker keeps beating.
    #
    # The recorder is injected so this file stays free of persistence concerns;
    # bin/temporal_worker wires it to WorkerReadinessObservation.record!.
    # @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-004
    class Heartbeat
      DEFAULT_INTERVAL_SECONDS = 30.0
      # Bounded so a beat stuck on external I/O cannot block the worker's
      # exit path; the loop's stop flag still ends it after the current beat.
      STOP_JOIN_TIMEOUT = 5

      # Beat payload: { role:, pid:, ready_at:, revision:, at: }. `at` is the
      # heartbeat timestamp; `ready_at` stays fixed at this process's boot so
      # readers can distinguish boot identity from current liveness.
      def self.start(roles:, identity:, recorder:, interval: DEFAULT_INTERVAL_SECONDS, clock: -> { Time.now.utc })
        new(roles:, identity:, recorder:, interval:, clock:).tap(&:start)
      end

      def initialize(roles:, identity:, recorder:, interval: DEFAULT_INTERVAL_SECONDS, clock: -> { Time.now.utc },
        sleeper: nil)
        @roles = roles.map(&:to_s)
        @identity = identity
        @recorder = recorder
        @interval = interval.to_f
        @clock = clock
        @ready_at = clock.call
        @sleeper = sleeper || method(:interruptible_sleep)
        @mutex = Mutex.new
        @stop_condition = ConditionVariable.new
        @stopped = false
        @thread = nil
        raise ArgumentError, "heartbeat interval must be positive" unless @interval.positive?
      end

      def start
        @thread = Thread.new { run }
        self
      end

      # Publishes one beat for every served role. Recording failures are
      # external I/O errors: warn and keep beating; readers treat a missing or
      # stale observation as unknown, so a dropped beat never fabricates
      # adoption evidence.
      def publish
        at = clock.call
        roles.each { |role| record_role(role, at) }
        self
      end

      def run
        until stopped?
          publish
          sleep_until_next_beat
        end
      end

      # Cooperative stop: flag the loop and wake a pending sleep without
      # killing the thread, then wait (bounded) for the in-flight beat.
      def stop
        mutex.synchronize do
          @stopped = true
          stop_condition.signal
        end
        thread&.join(STOP_JOIN_TIMEOUT)
        self
      end

      private

      attr_reader :clock, :identity, :interval, :mutex, :recorder, :roles, :sleeper, :stop_condition, :thread

      def stopped?
        mutex.synchronize { @stopped }
      end

      def sleep_until_next_beat
        sleeper.call(interval)
      end

      def interruptible_sleep(seconds)
        mutex.synchronize do
          return if @stopped

          stop_condition.wait(mutex, seconds)
        end
      end

      def record_role(role, at)
        recorder.call({ role:, pid: identity.fetch(:pid), ready_at: @ready_at,
                        revision: identity.fetch(:revision), at: })
      rescue StandardError => error
        warn "Failed to record worker readiness heartbeat for #{role}: #{error.class}: #{error.message}"
      end
    end
  end
end
