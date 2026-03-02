# frozen_string_literal: true

namespace :dev do
  desc "Mark stale agent runs as timed out and stop orphaned containers"
  task cleanup: :environment do
    count = 0
    AgentRun.active.find_each do |run|
      run.timeout!(error: "Marked stale on startup: process was restarted")
      run.log!("system", "Run marked as timed out during startup cleanup")
      count += 1
    end

    puts "  Resolved #{count} stale agent run(s)" if count > 0

    # Always process the queue — queued runs may be stranded if the job was
    # never re-enqueued after a restart (no cron schedule for this job).
    queued = AgentRun.queued.count
    if count > 0 || queued > 0
      ProcessRunQueueJob.perform_later
      puts "  Processing run queue (#{queued} queued)" if queued > 0
    end
  end
end
