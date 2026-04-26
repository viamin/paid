# frozen_string_literal: true

# Evaluates whether a release-please PR should be auto-merged based on
# the project's auto_release_granularity setting. Checks CI status and
# bump classification before merging.
#
# Triggered by:
# - GitHub webhooks (check_suite.completed, pull_request.opened/synchronize/labeled)
# - Poll loop via EvaluateAutoReleaseActivity (every cycle when auto_release enabled)
#
# Concurrency: at most one evaluation per project at a time.
class AutoReleaseEvaluationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :default

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "auto-release-#{arguments.first}" }
  )

  EXPECTED_MERGE_STATUSES = [ 405, 409, 422 ].freeze
  PAID_AUTO_RELEASED_LABEL = "paid-auto-released"

  def perform(project_id, pr_number: nil)
    project = Project.find_by(id: project_id)
    return unless project&.auto_release_enabled?

    client = project.github_token.client

    release_pr = find_release_pr(client, project, pr_number)
    return unless release_pr

    previous_version = fetch_previous_version(client, project)
    return unless previous_version

    result = ReleasePlease::ParseReleasePr.call(
      pr_data: release_pr,
      previous_version: previous_version
    )

    unless result
      Rails.logger.info(
        message: "auto_release.parse_failed",
        project_id: project.id,
        pr_number: release_pr.number
      )
      return
    end

    unless project.auto_release_allows_bump?(result.bump)
      Rails.logger.info(
        message: "auto_release.merge_skipped",
        project_id: project.id,
        pr_number: result.pr_number,
        reason: "granularity_mismatch",
        bump: result.bump,
        granularity: project.auto_release_granularity
      )
      return
    end

    unless all_checks_green?(client, project, release_pr)
      Rails.logger.info(
        message: "auto_release.merge_skipped",
        project_id: project.id,
        pr_number: result.pr_number,
        reason: "checks_not_green",
        bump: result.bump
      )
      return
    end

    merge_release_pr(client, project, result)
  end

  private

  def find_release_pr(client, project, pr_number)
    if pr_number
      pr_data = client.pull_request(project.full_name, pr_number)
      return pr_data if pr_data && !pr_data.merged_at && ReleasePlease::ParseReleasePr.release_please_pr?(pr_data)
      return nil
    end

    prs = client.pull_requests(project.full_name, state: "open")
    prs.find { |pr| ReleasePlease::ParseReleasePr.release_please_pr?(pr) }
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "auto_release.find_pr_failed",
      project_id: project.id,
      error: e.message
    )
    nil
  end

  def fetch_previous_version(client, project)
    content = client.contents(project.full_name, path: ".release-please-manifest.json")
    manifest = JSON.parse(Base64.decode64(content.content))
    manifest["."]
  rescue GithubClient::Error, JSON::ParserError, NoMethodError => e
    Rails.logger.warn(
      message: "auto_release.fetch_version_failed",
      project_id: project.id,
      error: e.message
    )
    nil
  end

  def all_checks_green?(client, project, pr_data)
    checks = client.check_runs_for_ref(project.full_name, pr_data.head.sha)

    if checks.nil? || checks.empty?
      # Empty check runs may mean "no CI configured" or "CI hasn't queued yet."
      # Use the commit status API as a secondary signal: GitHub returns "pending"
      # when statuses exist but haven't completed. If the combined state is
      # "pending", CI is likely still spinning up — wait for the next poll cycle.
      return combined_status_state_settled?(client, project, pr_data.head.sha)
    end

    checks.all? { |c| %w[success skipped neutral].include?(c[:conclusion]) }
  rescue GithubClient::ApiError => e
    if e.status == 403
      Rails.logger.info(
        message: "auto_release.check_runs_forbidden",
        project_id: project.id,
        error: e.message
      )
      return true
    end

    raise
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "auto_release.check_runs_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  # Returns true when the combined commit status is not "pending", meaning
  # either no status checks exist (repo has no CI) or all have completed.
  def combined_status_state_settled?(client, project, sha)
    state = client.combined_status_state(project.full_name, sha)
    state != "pending"
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "auto_release.combined_status_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  def merge_release_pr(client, project, result)
    client.merge_pull_request(
      project.full_name, result.pr_number,
      merge_method: project.merge_method
    )

    add_label(client, project, result.pr_number)
    add_comment(client, project, result)

    Rails.logger.info(
      message: "auto_release.merged",
      project_id: project.id,
      pr_number: result.pr_number,
      new_version: result.new_version,
      bump: result.bump,
      granularity: project.auto_release_granularity
    )
  rescue GithubClient::ApiError => e
    raise unless EXPECTED_MERGE_STATUSES.include?(e.status)

    Rails.logger.warn(
      message: "auto_release.merge_failed_expected",
      project_id: project.id,
      pr_number: result.pr_number,
      status: e.status,
      error: e.message
    )
  end

  def add_label(client, project, pr_number)
    client.add_labels_to_issue(project.full_name, pr_number, [ PAID_AUTO_RELEASED_LABEL ])
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "auto_release.add_label_failed",
      project_id: project.id,
      pr_number: pr_number,
      error: e.message
    )
  end

  def add_comment(client, project, result)
    comment = "This release PR was automatically merged by Paid's auto-release feature " \
              "(#{result.bump} bump, policy: #{project.auto_release_granularity})."
    client.add_comment(project.full_name, result.pr_number, comment)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "auto_release.add_comment_failed",
      project_id: project.id,
      pr_number: result.pr_number,
      error: e.message
    )
  end
end
