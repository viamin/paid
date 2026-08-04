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
# @spec AUTO-MERGE-003
class DependabotAutoMergeJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency
  include CiStatusVerification

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "dependabot-auto-merge-#{arguments.first}-#{arguments.second&.fetch(:pr_number, nil)}" }
  )

  DEPENDABOT_AUTHORS = %w[dependabot[bot] dependabot-preview[bot]].freeze
  EXPECTED_MERGE_STATUSES = [ 405, 409, 422 ].freeze
  PAID_AUTO_MERGED_LABEL = "paid-auto-merged-dependabot"
  SKIP_AUTO_MERGE_LABEL = Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL

  def perform(project_id, pr_number: nil)
    project = Project.find_by(id: project_id)
    return unless project&.auto_merge_dependabot?

    client = project.client

    if pr_number
      evaluate_single_pr(client, project, pr_number)
    else
      evaluate_all_prs(client, project)
    end
  end

  private

  def evaluate_single_pr(client, project, pr_number)
    pr_data = fetch_pr(client, project, pr_number)
    return unless pr_data

    return if skip_auto_merge_label?(project, pr_data)
    return if skip_unmergeable?(client, project, pr_data)

    merge_dependabot_pr(client, project, pr_data)
  end

  def evaluate_all_prs(client, project)
    candidates = find_dependabot_candidates(client, project)
    return if candidates.empty?

    candidates.each do |pr_summary|
      pr_num = pr_number_from(pr_summary)
      pr_data = fetch_pr(client, project, pr_num)
      next unless pr_data

      next if skip_auto_merge_label?(project, pr_data)
      next if skip_unmergeable?(client, project, pr_data)

      merged = merge_dependabot_pr(client, project, pr_data)
      break if merged
    end
  end

  def pr_number_from(pr_data)
    pr_data.respond_to?(:number) ? pr_data.number : pr_data[:number]
  end

  def skip_auto_merge_label?(project, pr_data)
    pr_labels = if pr_data.respond_to?(:labels)
      Array(pr_data.labels).map { |l| l.respond_to?(:name) ? l.name : l[:name] }
    else
      Array(pr_data[:labels]).map { |l| l[:name] }
    end

    return false unless pr_labels.include?(SKIP_AUTO_MERGE_LABEL)

    Rails.logger.info(
      message: "dependabot_auto_merge.skipped",
      project_id: project.id,
      pr_number: pr_number_from(pr_data),
      reason: "skip_auto_merge_label"
    )
    true
  end

  def skip_unmergeable?(client, project, pr_data)
    pr_num = pr_number_from(pr_data)

    unless mergeable?(pr_data)
      Rails.logger.info(
        message: "dependabot_auto_merge.skipped",
        project_id: project.id,
        pr_number: pr_num,
        reason: "not_mergeable"
      )
      return true
    end

    unless all_checks_green?(client, project, pr_data)
      Rails.logger.info(
        message: "dependabot_auto_merge.skipped",
        project_id: project.id,
        pr_number: pr_num,
        reason: "checks_not_green"
      )
      return true
    end

    false
  end

  def fetch_pr(client, project, pr_number)
    pr_data = client.pull_request(project.full_name, pr_number)
    return nil unless pr_data && dependabot_pr?(pr_data) && !merged?(pr_data)

    pr_data
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.fetch_pr_failed",
      project_id: project.id,
      pr_number: pr_number,
      error: e.message
    )
    nil
  end

  def find_dependabot_candidates(client, project)
    prs = client.pull_requests(project.full_name, state: "open")
    prs.select { |pr| dependabot_pr?(pr) && !merged?(pr) }
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "dependabot_auto_merge.find_pr_failed",
      project_id: project.id,
      error: e.message
    )
    []
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

  def ci_log_component
    "dependabot_auto_merge"
  end

  def merge_dependabot_pr(client, project, pr_data)
    pr_number = pr_number_from(pr_data)

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
    true
  rescue GithubClient::ApiError => e
    raise unless EXPECTED_MERGE_STATUSES.include?(e.status)

    Rails.logger.warn(
      message: "dependabot_auto_merge.merge_failed_expected",
      project_id: project.id,
      pr_number: pr_number,
      status: e.status,
      error: e.message
    )
    false
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
