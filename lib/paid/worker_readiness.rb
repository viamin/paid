# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Paid
  # File-based readiness signaling for background worker processes.
  #
  # Workers (Temporal, GoodJob) do not serve HTTP, so an orchestrator cannot
  # probe them the way it probes the web process. Instead each worker writes
  # a ready-flag file on startup and removes it when shutdown begins.
  # A sidecar or exec-based health check reads the file existence:
  #
  #   test -f "$WORKER_READINESS_FILE"
  #
  # The default flag path is scoped per worker process (program name plus
  # TEMPORAL_WORKER_MODE) so colocated workers on one host each keep an
  # independent flag. config/deploy.yml runs bin/jobs and two
  # bin/temporal_worker processes (TEMPORAL_WORKER_MODE=poll and =agent) on
  # the same host; a single shared path would let one worker's graceful
  # shutdown remove the flag out from under the others, and an orchestrator's
  # `test -f` check could not tell which worker is draining.
  #
  # This mirrors how `lib/paid/good_job_worker.rb` keeps testable logic out of
  # the bin/ scripts.
  module WorkerReadiness
    DEFAULT_FILE_PREFIX = "paid-worker-ready"

    module_function

    # Path to the readiness flag file. Overridable via WORKER_READINESS_FILE.
    # The default is scoped per worker (program name + TEMPORAL_WORKER_MODE)
    # so colocated workers do not share a single flag.
    def file_path(env = ENV)
      env["WORKER_READINESS_FILE"].presence ||
        File.join(Dir.tmpdir, default_file_name(env))
    end

    # Per-worker default flag file name, derived from the running program and,
    # for Temporal workers, TEMPORAL_WORKER_MODE. bin/jobs yields
    # "paid-worker-ready-jobs"; a temporal worker in poll mode yields
    # "paid-worker-ready-temporal_worker-poll". This keeps each colocated
    # worker's flag independent without requiring explicit configuration,
    # though config/deploy.yml sets WORKER_READINESS_FILE explicitly per role
    # for deterministic paths in production.
    def default_file_name(env = ENV)
      program = File.basename($PROGRAM_NAME, ".*")
      mode = env["TEMPORAL_WORKER_MODE"].presence
      mode ? "#{DEFAULT_FILE_PREFIX}-#{program}-#{mode}" : "#{DEFAULT_FILE_PREFIX}-#{program}"
    end

    # Write the ready flag. Safe to call repeatedly (overwrites).
    def mark_ready!(env = ENV)
      path = file_path(env)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, ready_payload)
    rescue StandardError => error
      warn "Failed to write worker readiness file: #{error.class}: #{error.message}"
    end

    # Remove the ready flag, signaling drain/shutdown to the orchestrator.
    def mark_not_ready!(env = ENV)
      path = file_path(env)
      File.delete(path) if File.exist?(path)
    rescue StandardError => error
      warn "Failed to remove worker readiness file: #{error.class}: #{error.message}"
    end

    # Whether the worker has marked itself ready.
    def ready?(env = ENV)
      File.exist?(file_path(env))
    end

    def ready_payload
      { pid: Process.pid, ready_at: Time.now.utc.iso8601 }.to_json
    end
  end
end
