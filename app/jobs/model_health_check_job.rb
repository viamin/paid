# frozen_string_literal: true

# Daily self-healing sweep for model availability problems. Combines two
# detectors and files a single consolidated issue into each account's self repo
# so an agent (or admin) can keep model configuration current without human
# polling:
#
#   * Models::DetectCatalogDrift       — provider shipped/retired first-party models
#   * Models::DetectBrokenRunnerModels — a runner's configured model was rejected
#                                        at runtime (model-not-found / CLI too old)
#
# Runs after the nightly ModelsSyncJob so drift is measured against a freshly
# seeded catalog.
class ModelHealthCheckJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "model_health_check"
  )

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    TenantContext.with_system_access do
      # Catalog drift is global — the LlmModel catalog is shared, not tenant data.
      drift = Models::DetectCatalogDrift.call
      checked = 0
      filed = 0

      Account.find_each do |account|
        project = TenantContext.with(account) { self_repo_project(account) }
        next unless project

        checked += 1
        filed += 1 if file_for_account(account, project, drift)
      rescue => e
        Rails.logger.warn(message: "model_health.account_failed", account_id: account.id, error: e.message)
      end

      Rails.logger.info(
        message: "model_health.check_completed",
        new_models: drift.new_model_count,
        deprecated_models: drift.deprecated_model_count,
        self_repos_checked: checked,
        issues_filed: filed,
        duration_ms: elapsed_ms(started_at)
      )
    end
  end

  private

  # Broken-runner detection is scoped to the account's own agent_runs so one
  # tenant's runner names / model ids / run ids never leak into another
  # tenant's self-repo issue.
  def file_for_account(account, project, drift)
    TenantContext.with(account) do
      broken = Models::DetectBrokenRunnerModels.call
      return false unless drift.drift? || broken.broken?

      Models::FileModelHealthIssue.call(project: project, drift: drift, broken: broken).filed?
    end
  end

  def self_repo_project(account)
    repo_full_name = account.tenant_setting&.self_repo_full_name.presence || ENV["PAID_REPO_FULL_NAME"]
    return if repo_full_name.blank?

    project = account.projects.detect { |candidate| candidate.full_name.casecmp?(repo_full_name) }
    return unless project&.github_credential_present?

    project
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
