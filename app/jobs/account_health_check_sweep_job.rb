# frozen_string_literal: true

# Daily account-wide sweep that recomputes configuration health checks for
# every project and writes the result to HealthChecks::Cache. The cached
# result is the single source of truth the project health page reads, so
# network-backed checks (which hit GitHub / the model registry) only ever run
# here — never synchronously in a request.
#
# A failure on one project is logged and skipped so a single misconfigured or
# raising project cannot abort the whole sweep.
class AccountHealthCheckSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "account_health_sweep"
  )

  def perform
    started_at = monotonic_clock
    checked = 0
    total_findings = 0

    TenantContext.with_system_access do
      # Project#effective_owner is a method (created_by || account.fallback_owner),
      # not an association, so preload the associations it resolves through to
      # avoid an N+1 across the project fleet.
      Project.includes(:created_by, :account).find_each do |project|
        result = HealthChecks::Coordinator.call(scope: :project, subject: project, include_network: true)
        HealthChecks::Cache.write(project, result)
        checked += 1
        total_findings += result.findings.size
      rescue => e
        Rails.logger.warn(
          message: "project_health.sweep_project_failed",
          project_id: project.id,
          error: e.message
        )
      end
    end

    Rails.logger.info(
      message: "project_health.sweep_completed",
      projects_checked: checked,
      total_findings: total_findings,
      duration_ms: elapsed_ms(started_at)
    )
  end

  private

  def monotonic_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
