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

    # Coordinates graceful-vs-forced shutdown across repeated INT/TERM signals.
    # The first signal requests a graceful shutdown; any subsequent signal
    # forces an immediate exit. This is the same pattern as
    # `bin/temporal_worker`, extracted so the state machine is testable.
    class ShutdownCoordinator
      def initialize
        @mutex = Mutex.new
        @started = false
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
