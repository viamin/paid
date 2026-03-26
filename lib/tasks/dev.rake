# frozen_string_literal: true

# Thin wrapper around Docker CLI calls so tests can stub without any_instance_of.
module DevCleanup
  module_function

  def find_orphaned_containers
    `docker ps -q --filter "label=paid.agent_run_id" 2>/dev/null`.split +
      `docker ps -q --filter "label=paid.service_container" 2>/dev/null`.split
  end

  def stop_containers(ids)
    Kernel.system("docker", "stop", *ids, out: File::NULL, err: File::NULL)
  end

  # After grace=0 cleanup stops all service containers, sync DB records.
  def mark_service_containers_stopped
    count = ServiceContainer.running.update_all(status: "stopped", docker_container_id: nil)
    puts "  Marked #{count} service container(s) as stopped" if count > 0
  end

  # For grace>0, use the provisioner to clean up service containers that no
  # longer have active agent runs referencing them.
  def cleanup_stale_service_containers
    provisioner = Containers::ServiceProvisioner.new
    count = 0
    ServiceContainer.running.find_each do |sc|
      next if sc.active_agent_run_count > 0

      provisioner.stop_orphaned_container!(sc)
      count += 1
    rescue => e
      warn "  WARNING: Failed to stop service container #{sc.name}: #{e.message}"
    end
    puts "  Cleaned up #{count} orphaned service container(s)" if count > 0
  end
end

namespace :dev do
  desc "Mark stale agent runs as timed out, stop their containers (+ orphans when grace=0), and process the run queue"
  task cleanup: :environment do
    raw = ENV.fetch("STARTUP_CLEANUP_GRACE_PERIOD", "0")
    grace = begin
      Integer(raw).clamp(0..).seconds
    rescue ArgumentError
      warn "  WARNING: Invalid STARTUP_CLEANUP_GRACE_PERIOD=#{raw.inspect}, defaulting to 0"
      0.seconds
    end

    stale_count = 0
    skipped_count = 0
    stale_container_ids = []

    AgentRun.active.find_each do |run|
      run.with_lock do
        run.reload
        next if run.finished?

        if grace.zero? || run.updated_at < grace.ago
          run.timeout!(error: "Marked stale on startup: process was restarted")
          run.log!("system", "Run marked as timed out during startup cleanup")
          run.issue&.update!(paid_state: "failed") unless run.issue&.paid_state == "failed"
          stale_container_ids << run.container_id if run.container_id.present?
          stale_count += 1
        else
          skipped_count += 1
        end
      end
    end

    puts "  Resolved #{stale_count} stale agent run(s)" if stale_count > 0
    puts "  Skipped #{skipped_count} recent run(s) for Temporal recovery" if skipped_count > 0

    # grace=0: stop ALL labeled containers (agent + service + orphaned).
    # grace>0: stop stale run containers + clean up service containers via provisioner.
    if grace.zero?
      orphaned = DevCleanup.find_orphaned_containers
      orphaned.uniq!
      if orphaned.any?
        puts "  Stopping #{orphaned.size} orphaned container(s)"
        DevCleanup.stop_containers(orphaned)
        # Mark all running service containers as stopped since we just removed them.
        # Only do this after a successful Docker stop — if find_orphaned_containers
        # returned empty (e.g. Docker unavailable), we must not blindly flip DB records.
        DevCleanup.mark_service_containers_stopped
      end
    else
      if stale_container_ids.any?
        stale_container_ids.uniq!
        puts "  Stopping #{stale_container_ids.size} container(s) for stale runs"
        DevCleanup.stop_containers(stale_container_ids)
      end
      # Clean up service containers for stale runs via provisioner reference counting.
      DevCleanup.cleanup_stale_service_containers
    end

    # Always process the queue — queued runs may be stranded if the job was
    # never re-enqueued after a restart (no cron schedule for this job).
    queued = AgentRun.queued.count
    if stale_count > 0 || queued > 0
      ProcessRunQueueJob.perform_later
      puts "  Processing run queue (#{queued} queued)" if queued > 0
    end
  end
end
