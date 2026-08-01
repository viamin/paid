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

    # Emit the structured completion metric before the broadcast so a transient
    # broadcast failure cannot swallow the completion signal.
    Rails.logger.info(
      message: "project_health.check_completed",
      project_id: project.id,
      findings_count: result.findings.size,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    )

    broadcast_result(project, result)
  end

  private

  def broadcast_result(project, result)
    Turbo::StreamsChannel.broadcast_update_to(
      [ project, :health_checks ],
      target: "health_check_result",
      partial: "projects/health_check/result",
      locals: { result: result }
    )
  end
end
