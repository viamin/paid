# frozen_string_literal: true

# Periodically collects CPU and memory metrics from running agent containers.
#
# Enqueued for each running agent run and re-enqueues itself until the run
# finishes. Collection interval defaults to 15 seconds to balance granularity
# with overhead. On consecutive failures the interval backs off (doubled per
# failure, capped at 5 minutes) so metrics resume automatically when Docker
# recovers, rather than permanently stopping collection.
class ContainerMetricsCollectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :metrics

  COLLECTION_INTERVAL = 15.seconds
  MAX_BACKOFF_INTERVAL = 5.minutes

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "container_metrics_#{arguments.first}" }
  )

  def perform(agent_run_id, consecutive_failures: 0)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run&.running? && agent_run.container_id.present?

    result = Containers::CollectMetrics.call(agent_run: agent_run)

    # Stop re-enqueuing when the container no longer exists — continued
    # retries would just produce log noise with no chance of recovery.
    return if result == :not_found

    next_failures = result ? 0 : consecutive_failures + 1
    wait = backoff_interval(next_failures)

    self.class.set(wait: wait).perform_later(agent_run_id, consecutive_failures: next_failures)
  end

  private

  # Exponential backoff: 30s, 60s, 120s, 240s, then capped at 5 minutes.
  # Resets to 15s on success (consecutive_failures == 0).
  def backoff_interval(consecutive_failures)
    return COLLECTION_INTERVAL if consecutive_failures.zero?

    [ COLLECTION_INTERVAL * (2**consecutive_failures), MAX_BACKOFF_INTERVAL ].min
  end
end
