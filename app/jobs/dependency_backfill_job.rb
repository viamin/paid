# frozen_string_literal: true

# Backfills GitHub issues that are referenced in dependency trees or tracker
# bodies but are missing from the local database. Without this, closed issues
# that were never synced can cause tracker-blocked and dependency-blocked issues
# to remain stuck indefinitely — the sync pipeline only fetches open issues
# during initial sync and only fetches updates after its watermark during
# incremental sync, so closed issues that predate the watermark are invisible.
class DependencyBackfillJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "dependency_backfill/#{arguments.first}" }
  )

  retry_on GithubClient::RateLimitError, wait: :polynomially_longer, attempts: 3

  MAX_ISSUES_PER_JOB = 25

  def perform(project_id, issue_numbers)
    project = Project.find_by(id: project_id)
    return unless project

    client = project.client
    backfilled_ids = []
    issue_numbers = issue_numbers.take(MAX_ISSUES_PER_JOB)
    existing_numbers = project.issues.where(github_number: issue_numbers).pluck(:github_number).to_set

    issue_numbers.each do |number|
      next if existing_numbers.include?(number)

      github_issue = client.issue(project.full_name, number)
      record = Issues::UpsertFromGithub.call(project: project, github_issue: github_issue)
      backfilled_ids << record.id
    rescue GithubClient::RateLimitError
      raise # let GoodJob retry after rate-limit resets
    rescue GithubClient::NotFoundError
      Rails.logger.warn(
        message: "dependency_backfill.issue_not_found",
        project_id: project_id,
        github_number: number
      )
    rescue => e
      Rails.logger.warn(
        message: "dependency_backfill.issue_failed",
        project_id: project_id,
        github_number: number,
        error_class: e.class.name,
        error: e.message
      )
    end

    backfilled_ids
  end
end
