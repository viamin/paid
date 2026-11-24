# frozen_string_literal: true

# Development-only scheduled scan of the PgHero Overview. Collects every
# addressable finding category through PgHero's Ruby methods and files
# deduplicated tracking issues in each account's self repository. Database
# and collector failures propagate so GoodJob records a failed check;
# GitHub failures retry a bounded number of times before surfacing. The
# manual rake entry point (`bin/rails development:pg_hero_overview_scan`)
# performs this job so verification uses the same path.
#
# @spec RAILS-CONTROL-PLANE-025 RAILS-CONTROL-PLANE-026 RAILS-CONTROL-PLANE-029
class PgHeroOverviewScanJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  self.perform_timeout = 300

  # One scan at a time: state rows and GitHub issue writes are idempotent,
  # but overlapping scans double the GitHub traffic and race the persistence
  # counters.
  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "pghero_overview_scan"
  )

  retry_on GithubClient::Error, wait: :polynomially_longer, attempts: 4

  def perform
    return unless Rails.env.development?

    TenantContext.with_system_access do
      Account.find_each do |account|
        project = TenantContext.with(account) { self_repo_project(account) }
        next unless project

        Development::PgHeroOverview::Scan.new(project: project).call
      end
    end
  end

  private

  def self_repo_project(account)
    repo_full_name = account.tenant_setting&.self_repo_full_name.presence || ENV["PAID_REPO_FULL_NAME"]
    return if repo_full_name.blank?

    owner, repo = repo_full_name.split("/", 2)
    project = account.projects.find_by("LOWER(owner) = ? AND LOWER(repo) = ?", owner&.downcase, repo&.downcase)
    return unless project&.github_credential_present?

    project
  end
end
