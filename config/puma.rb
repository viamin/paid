# frozen_string_literal: true

# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
# Bind to 0.0.0.0 so the server is reachable from external networks (e.g. Tailscale).
bind "tcp://0.0.0.0:#{ENV.fetch("PORT", 3000)}"

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

# ---------------------------------------------------------------------------
# Production hardening
#
# The directives below only take effect in cluster mode (two or more workers,
# i.e. WEB_CONCURRENCY >= 2). With the default single worker they are inert, so
# local development behavior is unchanged.
#
# Load balancer / proxy integration (see app/controllers/health_controller.rb):
#   GET /health/readiness — 200 when the app can serve traffic (DB reachable,
#                           migrations current). Use this to gate new deploys
#                           and route traffic.
#   GET /health/liveness  — 200 while the process is up. Use this to trigger an
#                           auto-restart of a hung or crashed worker/container.
# ---------------------------------------------------------------------------

# Restart workers that take too long to boot or stop responding to the master's
# heartbeat. Only applies in cluster mode. The default is generous because a
# cold Rails boot plus pending migrations can be slow; tighten in production if
# boots are consistently fast. Must remain greater than worker_check_interval
# (default 5s).
worker_timeout Integer(ENV.fetch("WORKER_TIMEOUT", 3600))

# Force-kill workers that have not shut down within this window during a phased
# restart or deploy, so a long-running request (e.g. a container exec stream)
# cannot block graceful deploys indefinitely. Only applies in cluster mode.
worker_shutdown_timeout Integer(ENV.fetch("WORKER_SHUTDOWN_TIMEOUT", 30))

# Run multiple workers for process-level fault tolerance. The default of 1 (env
# unset) preserves single-worker development behavior.
#
#   WEB_CONCURRENCY=2      run exactly 2 workers
#   WEB_CONCURRENCY=auto   run WEB_CONCURRENCY_AUTO workers (default 2)
#
# For production serving multiple paying users, 2+ workers are recommended so a
# single worker crash or memory leak cannot take down the entire control plane.
workers_count = ENV.fetch("WEB_CONCURRENCY", nil)
if workers_count == "auto"
  workers Integer(ENV.fetch("WEB_CONCURRENCY_AUTO", 2))
elsif workers_count
  workers Integer(workers_count)
end

# Preload the application in the master process before forking workers. This
# reduces per-worker memory via copy-on-write sharing, but requires that forked
# workers re-establish their own database connections (see before_worker_boot
# below).
#
# SolidCable persists broadcasts to PostgreSQL, so WebSocket/ActionCable
# behavior is safe under multi-worker + preload_app. Off by default; enable in
# production after confirming the connection pool (config/database.yml DB_POOL)
# can satisfy `workers * RAILS_MAX_THREADS` plus any in-process GoodJob threads.
preload_app_enabled = ENV.fetch("RAILS_PRELOAD_APP", "false") == "true"
preload_app! preload_app_enabled

# Forked workers inherit the master's open database sockets when preload_app is
# enabled and must discard them so each worker uses its own connections. This
# hook only fires in cluster mode; it is registered only when preload_app is on
# to avoid noise in the default single-worker setup.
if preload_app_enabled
  before_worker_boot do
    ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
  end
end
