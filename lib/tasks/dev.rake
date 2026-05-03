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

  # After kill_all cleanup stops all service containers, sync DB records.
  def mark_service_containers_stopped
    count = ServiceContainer.running.update_all(status: "stopped", docker_container_id: nil)
    puts "  Marked #{count} service container(s) as stopped" if count > 0
  end
end

namespace :dev do
  desc "Process stranded queued runs. Set STARTUP_CLEANUP_KILL_ALL=1 to also force-timeout all active runs and stop their containers."
  task cleanup: :environment do
    if ENV["STARTUP_CLEANUP_KILL_ALL"] == "1"
      stale_count = 0

      AgentRun.active.find_each do |run|
        run.with_lock do
          run.reload
          next if run.finished?

          run.timeout!(error: "#{AgentRun::STALE_CLEANUP_ERROR_PREFIX}: process was restarted")
          run.log!("system", "Run marked as timed out during startup cleanup")
          run.issue&.update!(paid_state: "failed") unless run.issue&.paid_state == "failed"
          stale_count += 1
        end
      end

      AgentRun.stale_claimed.find_each do |run|
        run.with_lock do
          run.reload
          next if run.finished?
          next unless run.claimed?

          run.timeout!(error: "#{AgentRun::STALE_CLEANUP_ERROR_PREFIX}: process was restarted")
          run.log!("system", "Stale claimed run marked as timed out during startup cleanup")
          run.issue&.update!(paid_state: "failed") unless run.issue&.paid_state == "failed"
          stale_count += 1
        end
      end

      puts "  Resolved #{stale_count} stale agent run(s)" if stale_count > 0

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

    end

    # Always process the queue — queued runs may be stranded if the job was
    # never re-enqueued after a restart (no cron schedule for this job).
    # Stale run detection is handled by StaleRunDetectorJob (cron every 5 min).
    queued = AgentRun.queued.count
    if queued > 0
      ProcessRunQueueJob.perform_later
      puts "  Processing run queue (#{queued} queued)"
    end
  end
end
