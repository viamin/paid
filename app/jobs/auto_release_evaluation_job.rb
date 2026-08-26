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
  include CiStatusVerification

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

    client = project.client

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
      record_attempt(
        project,
        release_pr.number,
        status: "failed",
        reason_code: AutoMergeAttempts::Record::REASON_PARSE_FAILED,
        message: "Paid could not classify the release PR for auto-merge.",
        credential_mode: credential_mode(project)
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
      record_attempt(
        project,
        result.pr_number,
        status: "skipped",
        reason_code: AutoMergeAttempts::Record::REASON_GRANULARITY_MISMATCH,
        message: "Release bump #{result.bump} exceeds the project's #{project.auto_release_granularity} auto-release policy.",
        credential_mode: credential_mode(project)
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
      record_attempt(
        project,
        result.pr_number,
        status: "skipped",
        reason_code: AutoMergeAttempts::Record::REASON_CHECKS_NOT_GREEN,
        message: "Required checks are not green yet.",
        credential_mode: credential_mode(project)
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
    unless content.respond_to?(:content)
      Rails.logger.warn(
        message: "auto_release.fetch_version_failed",
        project_id: project.id,
        error: "Expected file content response for .release-please-manifest.json",
        response_class: content.class.name
      )
      return nil
    end

    manifest = JSON.parse(Base64.decode64(content.content))
    manifest["."]
  rescue GithubClient::Error, JSON::ParserError => e
    Rails.logger.warn(
      message: "auto_release.fetch_version_failed",
      project_id: project.id,
      error: e.message
    )
    nil
  end

  def ci_log_component
    "auto_release"
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
    record_attempt(
      project,
      result.pr_number,
      status: "merged",
      credential_mode: credential_mode(project)
    )
  rescue GithubClient::ApiError => e
    raise unless EXPECTED_MERGE_STATUSES.include?(e.status)

    record_attempt(
      project,
      result.pr_number,
      status: "failed",
      reason_code: AutoMergeAttempts::Record::REASON_EXPECTED_MERGE_FAILURE,
      message: e.message,
      credential_mode: credential_mode(project)
    )
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

  def pull_request_issue(project, pr_number)
    project.issues.find_by(github_number: pr_number, is_pull_request: true)
  end

  def record_attempt(project, pr_number, **attributes)
    issue = pull_request_issue(project, pr_number)
    return unless issue

    AutoMergeAttempts::Record.call(project: project, issue: issue, actor_path: AutoMergeAttempts::Record::ACTOR_AUTO_RELEASE, **attributes)
  end

  def credential_mode(project)
    project.github_auth_source == "app" ? "github_app" : "pat"
  end
end
