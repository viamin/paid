# frozen_string_literal: true

# Evaluates whether a Dependabot PR should be auto-merged.
# Checks that the PR author is Dependabot, CI passes, and the PR is mergeable
# before merging. Review requirements are skipped since Dependabot updates are
# dependency-only changes.
#
# Triggered by:
# - GitHub webhooks (check_suite.completed, pull_request.opened/synchronize)
# - Poll loop via EvaluateDependabotAutoMergeActivity (every cycle when auto_merge enabled)
#
# Concurrency: at most one evaluation per project+PR at a time.
class DependabotAutoMergeJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "dependabot-auto-merge-#{arguments.first}-#{arguments.second&.fetch(:pr_number, nil)}" }
  )

  DEPENDABOT_AUTHORS = %w[dependabot[bot] dependabot-preview[bot]].freeze
  EXPECTED_MERGE_STATUSES = [ 405, 409, 422 ].freeze
  PAID_AUTO_MERGED_LABEL = "paid-auto-merged-dependabot"

  def perform(project_id, pr_number: nil)
    project = Project.find_by(id: project_id)
    return unless project&.auto_merge_dependabot?

    client = project.github_token.client

    dependabot_pr = find_dependabot_pr(client, project, pr_number)
    return unless dependabot_pr

    pr_num = dependabot_pr.respond_to?(:number) ? dependabot_pr.number : dependabot_pr[:number]

    unless mergeable?(dependabot_pr)
      Rails.logger.info(
        message: "dependabot_auto_merge.skipped",
        project_id: project.id,
        pr_number: pr_num,
        reason: "not_mergeable"
      )
      return
    end

    unless all_checks_green?(client, project, dependabot_pr)
      Rails.logger.info(
        message: "dependabot_auto_merge.skipped",
        project_id: project.id,
        pr_number: pr_num,
        reason: "checks_not_green"
      )
      return
    end

    merge_dependabot_pr(client, project, dependabot_pr)
  end

  private

  def find_dependabot_pr(client, project, pr_number)
    if pr_number
      pr_data = client.pull_request(project.full_name, pr_number)
      return pr_data if pr_data && dependabot_pr?(pr_data) && !merged?(pr_data)
      return nil
    end

    prs = client.pull_requests(project.full_name, state: "open")
    match = prs.find { |pr| dependabot_pr?(pr) && !merged?(pr) }
    return nil unless match

    client.pull_request(project.full_name, match.number)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.find_pr_failed",
      project_id: project.id,
      error: e.message
    )
    nil
  end

  def dependabot_pr?(pr_data)
    author = pr_data.respond_to?(:user) ? pr_data.user&.login : pr_data.dig(:user, :login)
    DEPENDABOT_AUTHORS.include?(author)
  end

  def merged?(pr_data)
    pr_data.respond_to?(:merged_at) ? pr_data.merged_at.present? : pr_data[:merged_at].present?
  end

  def mergeable?(pr_data)
    pr_data.respond_to?(:mergeable) ? pr_data.mergeable == true : pr_data[:mergeable] == true
  end

  def all_checks_green?(client, project, pr_data)
    sha = pr_data.respond_to?(:head) ? pr_data.head.sha : pr_data.dig(:head, :sha)
    checks = client.check_runs_for_ref(project.full_name, sha)

    if checks.nil? || checks.empty?
      return combined_status_ok?(client, project, sha, strict: false)
    end

    conclusions_green?(checks)
  rescue GithubClient::ApiError => e
    raise unless e.status == 403

    Rails.logger.info(
      message: "dependabot_auto_merge.check_runs_forbidden",
      project_id: project.id,
      error: e.message
    )
    workflow_runs_or_status_green?(client, project, sha)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.check_runs_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  # Reached when the Checks API is forbidden (e.g., fine-grained tokens have
  # no Checks permission). Verifies CI via the Actions API instead. If Actions
  # is also unavailable or empty, only an explicit "success" combined status
  # passes — "pending + 0 contexts" is not safe here because we never confirmed
  # the absence of check runs from non-Actions GitHub Apps.
  def workflow_runs_or_status_green?(client, project, sha)
    runs = client.workflow_runs_for_sha(project.full_name, sha)
    return conclusions_green?(runs) if runs.any?

    combined_status_ok?(client, project, sha, strict: true)
  rescue GithubClient::ApiError => e
    raise unless e.status == 403

    Rails.logger.info(
      message: "dependabot_auto_merge.workflow_runs_forbidden",
      project_id: project.id,
      error: e.message
    )
    combined_status_ok?(client, project, sha, strict: true)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.workflow_runs_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  def conclusions_green?(items)
    items.all? { |i| %w[success skipped neutral].include?(i[:conclusion]) }
  end

  # When +strict+ is false, "pending + 0 contexts" counts as "no CI configured"
  # and allows the merge — safe only when the caller has positive evidence (an
  # empty check_runs response) that no check runs exist either. When +strict+
  # is true (e.g., the Checks API was forbidden), only an explicit "success"
  # passes, since absence of statuses cannot prove absence of check runs.
  def combined_status_ok?(client, project, sha, strict:)
    status = client.combined_status(project.full_name, sha)
    return true if status[:state] == "success"
    !strict && status[:state] == "pending" && status[:total_count] == 0
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.combined_status_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  def merge_dependabot_pr(client, project, pr_data)
    pr_number = pr_data.respond_to?(:number) ? pr_data.number : pr_data[:number]

    client.merge_pull_request(
      project.full_name, pr_number,
      merge_method: project.merge_method
    )

    add_label(client, project, pr_number)
    add_comment(client, project, pr_number)

    Rails.logger.info(
      message: "dependabot_auto_merge.merged",
      project_id: project.id,
      pr_number: pr_number
    )
  rescue GithubClient::ApiError => e
    raise unless EXPECTED_MERGE_STATUSES.include?(e.status)

    Rails.logger.warn(
      message: "dependabot_auto_merge.merge_failed_expected",
      project_id: project.id,
      pr_number: pr_data.respond_to?(:number) ? pr_data.number : pr_data[:number],
      status: e.status,
      error: e.message
    )
  end

  def add_label(client, project, pr_number)
    client.add_labels_to_issue(project.full_name, pr_number, [ PAID_AUTO_MERGED_LABEL ])
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.add_label_failed",
      project_id: project.id,
      pr_number: pr_number,
      error: e.message
    )
  end

  def add_comment(client, project, pr_number)
    comment = "This Dependabot PR was automatically merged by Paid's Dependabot auto-merge feature."
    client.add_comment(project.full_name, pr_number, comment)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.add_comment_failed",
      project_id: project.id,
      pr_number: pr_number,
      error: e.message
    )
  end
end
