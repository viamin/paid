# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"
require "temporalio/worker/tuner"

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
  # The payload also publishes the checkout revision the worker booted from,
  # so a supervisor can distinguish an on-disk checkout from the code the
  # running worker actually loaded (see bin/dev-update's worker adoption
  # verification). The revision is commit identity only — never secrets,
  # credential payloads, or secret-bearing process arguments/environment.
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
    ADMISSION_POLL_INTERVAL = 0.05
    # Matches TrustedMeasurements::DeploymentSignal::ENV_KEY: the deploy
    # pipeline's revision identity when present, development HEAD otherwise.
    REVISION_ENV_KEY = "PAID_DEPLOYED_REVISION"
    GIT_ENVIRONMENT = {
      "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_COMMON_DIR" => nil,
      "GIT_INDEX_FILE" => nil
    }.freeze
    @activity_count = 0
    @activity_count_lock = Mutex.new
    @boot_revisions = {}

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
      revision = boot_revision(env)
      FileUtils.mkdir_p(File.dirname(path))
      @activity_count_lock.synchronize { @boot_revisions[path] = revision }
      write_payload(path, ready_payload(env, revision:))
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

    # The file flag above is an orchestrator-local contract: it cannot cross
    # the container boundary between the job and worker_* roles. Worker
    # processes therefore also publish their readiness identity as durable
    # liveness beats (see WorkerReadiness::Heartbeat and
    # WorkerReadinessObservation), which the trusted worker-adoption
    # measurement reads from any role's container.

    # The updater takes this lock exclusively before stopping workers. The
    # Temporal activity slot supplier checks shared ownership before polling,
    # while a used slot retains shared ownership through task release.
    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-004
    def admission_lock_path(env = ENV)
      "#{file_path(env)}.admission.lock"
    end

    # Supplies Temporal activity execution slots only after the worker can
    # acquire its shared admission lock. Temporal reserves a slot before it
    # polls a task, so an updater's exclusive lock keeps queued work from being
    # assigned and consuming an activity attempt while a restart is draining.
    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-004
    def activity_slot_supplier(slots:, env: ENV)
      ActivitySlotSupplier.new(slots:, env:)
    end

    # Activity counts are deliberately coarse, process-local readiness metadata:
    # the updater needs only to know whether stopping this worker would interrupt
    # an owner. It never contains activity inputs or customer data.
    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-004
    def activity_started!(env = ENV)
      update_activity_count!(env, 1)
    end

    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-004
    def activity_finished!(env = ENV)
      update_activity_count!(env, -1)
    end

    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-003
    def ready_payload(env = ENV, revision: boot_revision(env))
      { pid: Process.pid, ready_at: Time.now.utc.iso8601, revision:, active_activities: @activity_count }.to_json
    end

    # The revision identity of the code this worker process booted from:
    # the deploy pipeline's revision when PAID_DEPLOYED_REVISION is set,
    # otherwise the development checkout's HEAD SHA. Returns nil when the
    # revision cannot be determined; callers treat that as unknown, never
    # as a verified adoption.
    def boot_revision(env = ENV, root: nil)
      revision = env[REVISION_ENV_KEY]
      return revision unless revision.to_s.strip.empty?

      git_head_revision(root || default_revision_root)
    end

    # Rails.root when running under Rails; the process working directory for
    # bare-Ruby boot paths (spec subprocesses, early binstubs).
    def default_revision_root
      defined?(Rails) ? Rails.root : Dir.pwd
    end

    def git_head_revision(root)
      output, _error, status = Open3.capture3(GIT_ENVIRONMENT, "git", "-C", root.to_s, "rev-parse", "HEAD")
      status.success? ? output.strip : nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def update_activity_count!(env, change)
      path = file_path(env)
      return unless File.exist?(path)

      @activity_count_lock.synchronize do
        @activity_count = [ @activity_count + change, 0 ].max
        revision = @boot_revisions.fetch(path) { boot_revision(env) }
        write_payload(path, ready_payload(env, revision:))
      end
    rescue StandardError => error
      warn "Failed to update worker readiness activity count: #{error.class}: #{error.message}"
    end

    def write_payload(path, payload)
      temporary_path = "#{path}.#{Process.pid}.tmp"
      File.write(temporary_path, payload)
      File.rename(temporary_path, path)
    ensure
      File.delete(temporary_path) if defined?(temporary_path) && File.exist?(temporary_path)
    end

    # This is a Temporal custom slot supplier rather than an activity wrapper:
    # the latter runs only after Temporal has already assigned the task and
    # starts its heartbeat deadline. Unused SDK poll reservations do not retain
    # admission ownership; used permits retain it through task release.
    class ActivitySlotSupplier < Temporalio::Worker::Tuner::SlotSupplier::Custom
      Permit = Struct.new(:lock, :used)

      def initialize(slots:, env: ENV)
        @env = env
        @available_slots = slots
        @mutex = Mutex.new
        @available = ConditionVariable.new
      end

      def reserve_slot(_context, cancellation)
        permit = wait_for_permit(cancellation)
        yield permit if permit
      end

      def try_reserve_slot(_context)
        acquire_permit(nonblocking: true)
      end

      def mark_slot_used(context)
        permit = context.permit
        return if permit.used

        permit.lock = acquire_admission_lock
        permit.used = true
        WorkerReadiness.activity_started!(@env)
      end

      def release_slot(context)
        permit = context.permit
        WorkerReadiness.activity_finished!(@env) if permit.used
        permit.lock&.close
        return_slot
      end

      private

      attr_reader :env

      def wait_for_permit(cancellation)
        until cancellation.canceled?
          permit = acquire_permit(nonblocking: true)
          return permit if permit

          wait_for_slot
        end
      end

      def acquire_permit(nonblocking:)
        return unless claim_slot(nonblocking:)

        lock = acquire_admission_lock(nonblocking: true)
        return Permit.new(nil, false) if lock

        return_slot
        nil
      rescue SystemCallError
        return_slot
        nil
      ensure
        lock&.close
      end

      def acquire_admission_lock(nonblocking: false)
        lock = File.open(WorkerReadiness.admission_lock_path(env), File::RDWR | File::CREAT, 0o644)
        operation = File::LOCK_SH
        operation |= File::LOCK_NB if nonblocking
        return lock if lock.flock(operation)

        lock.close
        nil
      end

      def claim_slot(nonblocking:)
        @mutex.synchronize do
          return false if nonblocking && @available_slots.zero?

          @available.wait(@mutex, ADMISSION_POLL_INTERVAL) while @available_slots.zero?
          @available_slots -= 1
          true
        end
      end

      def wait_for_slot
        @mutex.synchronize { @available.wait(@mutex, ADMISSION_POLL_INTERVAL) }
      end

      def return_slot
        @mutex.synchronize do
          @available_slots += 1
          @available.signal
        end
      end
    end
  end
end
