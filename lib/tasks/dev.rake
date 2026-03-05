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
end

namespace :dev do
  desc "Mark stale agent runs as timed out, stop orphaned containers, and process the run queue"
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

    # TODO(#284): Integrate Containers::ServiceProvisioner here so startup cleanup
    # can clean up service containers for stale runs using its "only stop if no
    # other active runs" logic. Currently service containers are only cleaned up
    # in the grace=0 branch via find_orphaned_containers (which catches all
    # labeled containers directly via the Docker CLI). In the grace>0 branch,
    # service containers for timed-out runs are left running until the next
    # grace=0 cleanup or manual intervention.

    # Stop containers belonging to timed-out runs, or all labeled containers when grace is zero.
    if grace.zero?
      orphaned = DevCleanup.find_orphaned_containers
      orphaned.uniq!
      if orphaned.any?
        puts "  Stopping #{orphaned.size} orphaned container(s)"
        DevCleanup.stop_containers(orphaned)
      end
    elsif stale_container_ids.any?
      stale_container_ids.uniq!
      puts "  Stopping #{stale_container_ids.size} container(s) for stale runs"
      DevCleanup.stop_containers(stale_container_ids)
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
