# frozen_string_literal: true

class ProjectDashboardMetricsSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "project_dashboard_metrics_sweep"
  )

  # @spec PROJECT-DASHBOARD-METRICS-002
  def perform
    TenantContext.with_system_access do
      Project.where(active: true).find_each do |project|
        ProjectDashboardMetrics::Snapshot.refresh(project: project)
      rescue StandardError => e
        Rails.logger.warn(
          message: "project_dashboard_metrics.refresh_failed",
          project_id: project.id,
          error_class: e.class.name
        )
      end
    end
  end
end
