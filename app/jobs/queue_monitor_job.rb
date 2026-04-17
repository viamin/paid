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

    result = Scaling::QueueMonitor.call

    Account.find_each do |account|
      account_result = Scaling::QueueMonitor.call(account: account)
      Scaling::QueueAlert.call(account: account, alerts: account_result.alerts) if account_result.alerts.any?

      broadcast_queue_health(account, account_result) if account_result.queue_depths.any?
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "scaling.queue_monitor_job.completed",
      global_healthy: result.healthy?,
      alert_count: result.alerts.size,
      duration_ms: duration_ms
    )
  end

  private

  def broadcast_queue_health(account, result)
    Turbo::StreamsChannel.broadcast_update_to(
      [ account, :live_dashboard ],
      target: "queue-health",
      partial: "dashboard/queue_health",
      locals: { queue_depths: result.queue_depths, healthy: result.healthy? }
    )
  end
end
