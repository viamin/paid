# frozen_string_literal: true

# Monitors queue depths across GoodJob and Temporal task queues, alerting
# when queues grow beyond healthy thresholds. Publishes notifications per
# account so operators see queue health in their dashboard.
#
# Scheduled via GoodJob cron every 5 minutes.
class QueueMonitorJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "queue_monitor"
  )

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    global_result = Scaling::QueueMonitor.call
    global_depths = global_result.queue_depths.reject { |d| d.type == :agent_run_queue }

    agent_run_counts = AgentRun.waiting.joins(:project)
      .group("projects.account_id")
      .count

    Account.find_each do |account|
      depth = agent_run_counts.fetch(account.id, 0)
      account_agent_result = Scaling::QueueMonitor.call(account: account, only: :agent_run_queue, precomputed_depth: depth)
      combined_depths = global_depths + account_agent_result.queue_depths
      combined_alerts = global_result.alerts.select { |a| a.queue_type != :agent_run_queue } + account_agent_result.alerts

      combined_healthy = global_result.healthy? && account_agent_result.healthy?
      combined_result = Scaling::QueueMonitor::Result.new(
        queue_depths: combined_depths,
        alerts: combined_alerts,
        healthy?: combined_healthy
      )
      Scaling::QueueMonitor.write_cache(account, combined_result)

      Scaling::QueueAlert.call(account: account, alerts: combined_alerts)
      broadcast_queue_health(account, combined_depths, combined_healthy) if combined_depths.any?
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "scaling.queue_monitor_job.completed",
      global_healthy: global_result.healthy?,
      alert_count: global_result.alerts.size,
      duration_ms: duration_ms
    )
  end

  private

  def broadcast_queue_health(account, queue_depths, healthy)
    Turbo::StreamsChannel.broadcast_update_to(
      [ account, :live_dashboard ],
      target: "queue-health",
      partial: "dashboard/queue_health",
      locals: { queue_depths: queue_depths, healthy: healthy }
    )
  end
end
