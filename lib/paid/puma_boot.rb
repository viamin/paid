# frozen_string_literal: true

module Paid
  # Helpers for Puma's `before_worker_boot` hook in `config/puma.rb`.
  #
  # When Puma runs with `preload_app!` enabled in cluster mode (two or more
  # workers), each worker is forked from the master process after the
  # application has been fully loaded. Four state items are unsafe to keep
  # across that fork and must be either discarded or re-established:
  #
  # 1. ActiveRecord connection sockets — the kernel shares the file descriptor,
  #    so forked workers must clear the inherited pool (Puma fork-after-preload
  #    pattern; see config/puma.rb).
  # 2. GoodJob's async scheduler threads (RAILS-CONTROL-PLANE-003,
  #    RAILS-CONTROL-PLANE-013) — `preload_app!` starts them in the master
  #    before fork, and `fork(2)` only continues the calling thread, so a
  #    worker inherits the Ruby scheduler objects with none of the OS threads
  #    that were driving them. Left alone, those stranded objects keep
  #    referencing the master's pre-fork database connections, and clearing the
  #    pool out from under a scheduler that still believes it owns a connection
  #    produces `ActiveRecord::ConnectionNotEstablished` ("PQsocket() can't get
  #    socket descriptor"). GoodJob documents shutting its schedulers down
  #    before fork and restarting them after as the fix for async execution
  #    under Puma cluster mode.
  # 3. The Temporal client connection — its TCP socket and the
  #    `@temporal_mutex` serializing connect calls are not fork-safe; a bare
  #    reuse can either return a stale master-side connection or block all
  #    callers behind a mutex the rest of the process shares.
  # 4. The lazy `require "temporalio/client"` itself — paying this in a Puma
  #    worker boot, rather than inside the 2-second `/ready` probe timeout,
  #    avoids flapping readiness on cold worker boot after a rolling deploy.
  #
  # `call_after_fork` composes the per-worker recovery steps in one helper so
  # the Puma config can stay declarative and the logic remains unit-testable
  # without booting Puma. `shutdown_good_job!` is called separately, from the
  # master, before each fork (see config/puma.rb).
  module PumaBoot
    module_function

    # Run all post-fork recovery for a freshly forked Puma worker.
    # Safe to call repeatedly (each step is idempotent); the Temporal warming
    # thread is the one non-idempotent step and is intentionally fire-and-forget.
    # @spec RAILS-CONTROL-PLANE-013
    def call_after_fork
      clear_active_record_connections!
      restart_good_job!
      reset_temporal_client!
      warm_temporal_client_async
    end

    # Discard inherited ActiveRecord connection sockets so each forked worker
    # opens its own pool entries. No-op in single-worker mode or when AR has
    # not been loaded yet.
    def clear_active_record_connections!
      return unless defined?(ActiveRecord::Base)
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    # Stop GoodJob's async scheduler threads in the master, before Puma forks
    # a worker. Called from `config/puma.rb`'s `before_fork` hook, which runs
    # in the master process. No-op when GoodJob has not been loaded.
    def shutdown_good_job!
      return unless defined?(GoodJob)
      GoodJob.shutdown
    end

    # Restart GoodJob's async scheduler threads in a freshly forked worker, so
    # it runs against connections established after `clear_active_record_connections!`
    # rather than objects stranded by the fork. No-op when GoodJob has not been
    # loaded.
    def restart_good_job!
      return unless defined?(GoodJob)
      GoodJob.restart
    end

    # Reset the memoized Temporal client (and observability runtime) so the
    # next `Paid.temporal_client` call re-requires and re-connects cleanly. The
    # mutexes and instance variables stay, which is intentional: the locks must
    # outlive the connection so concurrent callers serialize on connect.
    def reset_temporal_client!
      Paid.reset_temporal_client! if defined?(Paid)
    end

    # Eagerly establish the Temporal client in a background thread so the
    # first `/ready` probe on a freshly booted worker doesn't pay the cold
    # gem-load + connect cost inline. Boot never blocks on the warm:
    #
    #   * A warm failure is logged and swallowed — the `/ready` probe will
    #     still surface it via its existing `temporal_healthy?` rescue.
    #   * The thread is detached; its lifetime is bounded by the worker's.
    #
    # @return [Thread] the background warming thread (kept for tests).
    def warm_temporal_client_async
      Thread.new do
        Thread.current.name = "paid-temporal-warm"
        begin
          Paid.temporal_client
        rescue StandardError => error
          warn "temporal client warm failed: #{error.class}: #{error.message}"
        end
      end
    end
  end
end
