# frozen_string_literal: true

# Periodically collects CPU and memory metrics from running service containers.
#
# Re-enqueues itself while the service container remains in the running state so
# operators can inspect ongoing Postgres/Redis/etc. resource usage and detect
# pressure before the container crashes.
class ServiceContainerMetricsCollectionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :metrics

  COLLECTION_INTERVAL = 15.seconds
  MAX_BACKOFF_INTERVAL = 5.minutes

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "service_container_metrics_#{arguments.first}" }
  )

  def perform(service_container_id, consecutive_failures: 0)
    service_container = ServiceContainer.find_by(id: service_container_id)
    return unless service_container&.running? && service_container.docker_container_id.present?

    result = Containers::CollectServiceMetrics.call(service_container: service_container)
    return if result == :not_found

    next_failures = result ? 0 : consecutive_failures + 1
    wait = backoff_interval(next_failures)

    self.class.set(wait: wait).perform_later(service_container_id, consecutive_failures: next_failures)
  end

  private

  def backoff_interval(consecutive_failures)
    return COLLECTION_INTERVAL if consecutive_failures.zero?

    [ COLLECTION_INTERVAL * (2**consecutive_failures), MAX_BACKOFF_INTERVAL ].min
  end
end
