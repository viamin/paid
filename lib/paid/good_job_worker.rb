# frozen_string_literal: true

module Paid
  # Helpers for the dedicated GoodJob worker entrypoint (`bin/jobs`).
  #
  # Only dependency-free logic lives here so it can be unit-tested without
  # booting Rails. The I/O bootstrap (DB pool resizing, signal trapping, and
  # the GoodJob capsule lifecycle) lives in `bin/jobs`, mirroring how
  # `bin/temporal_worker` pairs with `Paid::TemporalWorkerConfig`.
  module GoodJobWorker
    # GoodJob runs `max_threads` job-execution threads, each of which can hold a
    # DB connection while a job runs. On top of that, the capsule runs a
    # notifier (LISTEN/NOTIFY), a poller, and may enqueue cron work, so reserve
    # a small fixed overhead to avoid "could not obtain a connection from the
    # pool" mid-job.
    DB_POOL_OVERHEAD = 3

    DEFAULT_SHUTDOWN_TIMEOUT = 25
    DEFAULT_FORCE_EXIT_BUFFER = 10

    module_function

    # Minimum primary DB pool size needed to run `max_threads` worker threads
    # plus the capsule's own connections without exhausting the pool.
    def min_required_db_pool(max_threads:)
      max_threads + DB_POOL_OVERHEAD
    end

    # Graceful shutdown window added on top of GoodJob's own shutdown timeout
    # before the entrypoint forces an exit. Configurable so deployments can keep
    # it inside Kamal's signal wait budget.
    def force_exit_buffer(env = ENV)
      Integer(env.fetch("GOOD_JOB_FORCE_EXIT_BUFFER_SECONDS", DEFAULT_FORCE_EXIT_BUFFER.to_s))
    rescue ArgumentError
      DEFAULT_FORCE_EXIT_BUFFER
    end

    # Total wall-clock seconds before a stuck graceful shutdown is forced.
    def forced_exit_timeout(shutdown_timeout:, force_exit_buffer:)
      shutdown_timeout + force_exit_buffer
    end

    # @spec RAILS-CONTROL-PLANE-030
    # Evaluates the dedicated worker's independent liveness signals. The caller
    # owns database reads and recovery so this remains deterministic and can run
    # before Rails has fully booted.
    class HealthMonitor
      DEFAULT_HEARTBEAT_TIMEOUT = 90
      DEFAULT_PROGRESS_TIMEOUT = 90
      Result = Data.define(:status, :reason, :observed_at, :runnable_jobs) do
        def healthy?
          status == :healthy
        end

        def degraded?
          !healthy?
        end
      end

      def initialize(now: -> { Time.now.utc }, heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT,
        progress_timeout: DEFAULT_PROGRESS_TIMEOUT)
        @clock = now
        @heartbeat_timeout = heartbeat_timeout
        @progress_timeout = progress_timeout
        @progress_windows = {}
        @missing_process_since = nil
      end

      def observe(snapshot, now: clock.call)
        return observe_missing_process(snapshot, now) unless snapshot[:process]

        @missing_process_since = nil
        return result(:stale_process_heartbeat, snapshot, now) if heartbeat_stale?(snapshot[:process], now)
        return result(:scheduler_unavailable, snapshot, now) unless snapshot.fetch(:schedulers_running, true)

        observe_progress(snapshot, now)
      end

      private

      attr_reader :clock, :heartbeat_timeout, :progress_timeout

      def observe_progress(snapshot, now)
        waiting = schedulers(snapshot).each_with_index.filter_map do |scheduler, index|
          next unless waiting_with_available_thread?(scheduler)

          [ [ index, scheduler[:queues] || scheduler["queues"] ], scheduler ]
        end.to_h
        @progress_windows.keep_if { |key, _window| waiting.key?(key) }
        stalled = waiting.map { |key, scheduler| progress_stalled?(key, scheduler, now) }.any?
        result(stalled ? :stalled_queue_progress : :healthy, snapshot, now)
      end

      def observe_missing_process(snapshot, now)
        @missing_process_since ||= now
        return result(:healthy, snapshot, now) if now - @missing_process_since <= heartbeat_timeout

        result(:missing_process_heartbeat, snapshot, now)
      end

      def heartbeat_stale?(process, now)
        updated_at = process[:updated_at] || process["updated_at"]
        updated_at.nil? || now - updated_at > heartbeat_timeout
      end

      def waiting_with_available_thread?(scheduler)
        runnable_jobs = scheduler[:runnable_jobs] || scheduler["runnable_jobs"] || 0
        runnable_jobs.positive? && available_threads(scheduler).positive?
      end

      def progress_stalled?(key, scheduler, now)
        progress = progress_token(scheduler)
        window = @progress_windows[key]
        if window.nil? || window[:progress] != progress
          @progress_windows[key] = { progress:, observed_at: now }
          return false
        end

        now - window[:observed_at] > progress_timeout
      end

      # GoodJob updates execution_at as it dispatches a job, before the job
      # completes. Tracking it alongside the terminal execution count prevents
      # a legitimate dispatch from looking stalled while it is still running.
      def progress_token(scheduler)
        [ scheduler[:total_executions_count] || scheduler["total_executions_count"] || 0,
          scheduler[:execution_at] || scheduler["execution_at"] ]
      end

      def schedulers(snapshot)
        process = snapshot.fetch(:process)
        process[:schedulers] || process["schedulers"] || []
      end

      def available_threads(scheduler)
        scheduler[:available_threads] || scheduler["available_threads"] || 0
      end

      def result(reason, snapshot, now)
        Result.new(
          status: reason == :healthy ? :healthy : :degraded,
          reason:,
          observed_at: now,
          runnable_jobs: snapshot.fetch(:runnable_jobs, 0)
        )
      end
    end

    # @spec RAILS-CONTROL-PLANE-030
    # Starts one graceful recovery without touching GoodJob job ownership. The
    # GoodJob shutdown path remains responsible for draining or retaining locks.
    class RecoveryCoordinator
      def initialize(readiness:, shutdown:)
        @readiness = readiness
        @shutdown = shutdown
        @mutex = Mutex.new
        @started = false
      end

      def recover
        return false unless claim_recovery

        @readiness.mark_not_ready!
        @shutdown.call
        true
      end

      private

      def claim_recovery
        @mutex.synchronize do
          return false if @started

          @started = true
        end
      end
    end

    # Coordinates graceful-vs-forced shutdown across repeated INT/TERM signals.
    # The first signal requests a graceful shutdown; any subsequent signal
    # forces an immediate exit. This is the same pattern as
    # `bin/temporal_worker`, extracted so the state machine is testable.
    class ShutdownCoordinator
      def initialize
        @mutex = Mutex.new
        @started = false
      end

      # @spec RAILS-CONTROL-PLANE-032
      def install_signal_handlers(&handler)
        %w[INT TERM].each do |signal|
          Signal.trap(signal) { Thread.new { handler.call(trigger, signal) } }
        end
      end

      # @return [Symbol] :graceful on the first trigger, :force_exit after that.
      def trigger
        @mutex.synchronize do
          return :force_exit if @started

          @started = true
          :graceful
        end
      end

      def shutdown_started?
        @mutex.synchronize { @started }
      end
    end
  end
end
