# frozen_string_literal: true

class ProjectHealthCheckJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "project_health_check_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  def perform(project_id)
    project = Project.find(project_id)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = HealthChecks::Coordinator.call(
      scope: :project,
      subject: project,
      include_network: true
    )
    HealthChecks::Cache.write(project, result)

    Rails.logger.info(
      message: "project_health.check_completed",
      project_id: project.id,
      findings_count: result.findings.size,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    )
  end
end
