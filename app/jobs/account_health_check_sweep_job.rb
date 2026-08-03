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
    account_ids = Set.new

    TenantContext.with_system_access do
      # Project#effective_owner is a method (created_by || account.fallback_owner),
      # not an association, so preload the associations it resolves through to
      # avoid an N+1 across the project fleet. `created_by` is preloaded here;
      # the fallback-owner path (for orphaned projects with no created_by) is
      # batch-resolved separately in effective_owners_by_project_id below,
      # since Account#fallback_owner always queries and can't be preloaded.
      #
      # owner_findings_cache is shared across every Coordinator.call below so
      # runner/user findings for a given owner (including network-backed
      # checks) are computed once per sweep, not once per project.
      owner_findings_cache = {}
      effective_owners = effective_owners_by_project_id

      Project.includes(:created_by, :account).find_each do |project|
        result = HealthChecks::Coordinator.call(
          scope: :project, subject: project, include_network: true,
          owner_findings_cache: owner_findings_cache,
          effective_owner: effective_owners[project.id]
        )
        HealthChecks::Cache.write(project, result)
        checked += 1
        total_findings += result.findings.size
        account_ids.add(project.account_id)
      rescue => e
        Rails.logger.warn(
          message: "project_health.sweep_project_failed",
          project_id: project.id,
          error: e.message
        )
      end

      # Drive the notification pipeline: publish for firing checks and
      # auto-resolve for projects that are now clean (RDR-049 §8).
      Account.where(id: account_ids.to_a).find_each do |account|
        Notifications::Rule.evaluate_all(account: account)
      rescue => e
        Rails.logger.warn(
          message: "project_health.notification_evaluate_all_failed",
          account_id: account.id,
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

  # Batch-resolves Account#fallback_owner for every orphaned project (no
  # created_by) up front, in two queries total regardless of fleet size,
  # instead of one Account#fallback_owner query per orphaned project inside
  # the main sweep loop.
  def effective_owners_by_project_id
    orphaned = Project.where(created_by_id: nil).pluck(:id, :account_id)
    return {} if orphaned.empty?

    fallback_owner_ids = Account.batch_fallback_owner_ids(orphaned.map(&:last))
    fallback_owners = User.where(id: fallback_owner_ids.values.uniq).index_by(&:id)

    orphaned.each_with_object({}) do |(project_id, account_id), memo|
      memo[project_id] = fallback_owners[fallback_owner_ids[account_id]]
    end
  end

  def monotonic_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
