# frozen_string_literal: true

# Periodically collects CPU and memory metrics from running agent containers.
#
# Enqueued for each running agent run and re-enqueues itself until the run
# finishes. Collection interval defaults to 15 seconds to balance granularity
# with overhead.
class ContainerMetricsCollectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  COLLECTION_INTERVAL = 15.seconds

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "container_metrics_#{arguments.first}" }
  )

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run&.running?

    Containers::CollectMetrics.call(agent_run: agent_run)

    self.class.set(wait: COLLECTION_INTERVAL).perform_later(agent_run_id)
  end
end
