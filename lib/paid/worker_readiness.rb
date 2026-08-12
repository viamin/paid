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
  # This mirrors how `lib/paid/good_job_worker.rb` keeps testable logic out of
  # the bin/ scripts.
  module WorkerReadiness
    DEFAULT_FILE_NAME = "paid-worker-ready"

    module_function

    # Path to the readiness flag file. Overridable via WORKER_READINESS_FILE.
    def file_path(env = ENV)
      env["WORKER_READINESS_FILE"].presence || File.join(Dir.tmpdir, DEFAULT_FILE_NAME)
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
