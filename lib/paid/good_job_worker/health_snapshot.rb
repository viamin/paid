# frozen_string_literal: true

module Paid
  module GoodJobWorker
    # Read-only GoodJob observations kept separate from the pure health policy.
    # @spec RAILS-CONTROL-PLANE-030
    class HealthSnapshot
      def initialize(pid: Process.pid, schedulers: nil)
        @pid = pid
        @schedulers = schedulers
      end

      def call
        process = GoodJob::Process.where("state ->> 'pid' = ?", @pid.to_s).order(updated_at: :desc).first
        states = process&.state&.fetch("schedulers", []) || []
        runnable = runnable_jobs
        observed = states.map do |scheduler|
          scheduler.merge("runnable_jobs" => runnable.queue_string(scheduler.fetch("queues")).count)
        end

        {
          process: process && { updated_at: process.updated_at, schedulers: observed },
          schedulers_running: (@schedulers || GoodJob::Scheduler.instances).all?(&:running?),
          runnable_jobs: runnable.count
        }
      rescue ActiveRecord::ActiveRecordError
        { process: nil, runnable_jobs: 0 }
      end

      private

      def runnable_jobs
        GoodJob::Job.unfinished.only_scheduled.exclude_paused.advisory_unlocked.where(locked_by_id: nil)
      end
    end
  end
end
