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
    # Mark any active agent runs as timed out — they can't recover after a restart.
    # This is the same thing StaleRunDetectorJob does, but immediate instead of
    # waiting agent_timeout + 10 minutes.
    count = 0
    AgentRun.active.find_each do |run|
      run.with_lock do
        run.reload
        next if run.finished?

        run.timeout!(error: "Marked stale on startup: process was restarted")
        run.log!("system", "Run marked as timed out during startup cleanup")
        run.issue&.update!(paid_state: "failed") unless run.issue&.paid_state == "failed"
        count += 1
      end
    end

    puts "  Resolved #{count} stale agent run(s)" if count > 0

    # Stop orphaned agent and service containers left over from previous runs.
    orphaned = DevCleanup.find_orphaned_containers
    orphaned.uniq!
    if orphaned.any?
      puts "  Stopping #{orphaned.size} orphaned container(s)"
      DevCleanup.stop_containers(orphaned)
    end

    # Always process the queue — queued runs may be stranded if the job was
    # never re-enqueued after a restart (no cron schedule for this job).
    queued = AgentRun.queued.count
    if count > 0 || queued > 0
      ProcessRunQueueJob.perform_later
      puts "  Processing run queue (#{queued} queued)" if queued > 0
    end
  end
end
