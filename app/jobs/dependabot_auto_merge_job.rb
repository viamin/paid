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
  MERGE_PERMISSION_COMMENT_MARKER = "<!-- paid: dependabot-merge-permission-rejection -->"

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
    return if skip_merge_permission_cooldown?(project, pr_data)
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
      next if skip_merge_permission_cooldown?(project, pr_data)
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
    record_attempt(
      project,
      pr_number_from(pr_data),
      status: "skipped",
      reason_code: AutoMergeAttempts::Record::REASON_SKIP_LABEL,
      message: "Auto-merge skipped because the PR has the #{SKIP_AUTO_MERGE_LABEL} label.",
      credential_mode: AutoMergeAttempt.primary_credential_mode(project)
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
      record_attempt(
        project,
        pr_num,
        status: "skipped",
        reason_code: AutoMergeAttempts::Record::REASON_NOT_MERGEABLE,
        message: "GitHub is not reporting this pull request as mergeable yet.",
        credential_mode: AutoMergeAttempt.primary_credential_mode(project)
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
      record_attempt(
        project,
        pr_num,
        status: "skipped",
        reason_code: AutoMergeAttempts::Record::REASON_CHECKS_NOT_GREEN,
        message: "Required checks are not green yet.",
        credential_mode: AutoMergeAttempt.primary_credential_mode(project)
      )
      return true
    end

    false
  end

  def skip_merge_permission_cooldown?(project, pr_data)
    pr_num = pr_number_from(pr_data)
    issue = pull_request_issue(project, pr_num)
    return false unless issue&.merge_permission_rejected? && !issue.merge_permission_retry_due?

    Rails.logger.info(
      message: "dependabot_auto_merge.merge_permission_cooldown",
      project_id: project.id,
      pr_number: pr_num
    )
    record_attempt(
      project,
      pr_num,
      status: "skipped",
      reason_code: AutoMergeAttempts::Record::REASON_MERGE_PERMISSION_COOLDOWN,
      message: "Auto-merge is waiting for the merge-permission cooldown window to elapse.",
      credential_mode: AutoMergeAttempt.primary_credential_mode(project)
    )
    true
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

    merge_dependabot_pr_with(
      client,
      project,
      pr_number,
      credential_mode: AutoMergeAttempt.primary_credential_mode(project)
    )
  rescue GithubClient::ApiError => e
    fallback_client = workflow_permission_rejection?(e) && project.git_push_fallback_client
    if fallback_client
      Rails.logger.info(
        message: "dependabot_auto_merge.retrying_with_pat_fallback",
        project_id: project.id,
        pr_number: pr_number
      )
      begin
        return merge_dependabot_pr_with(fallback_client, project, pr_number, credential_mode: "pat_fallback")
      rescue GithubClient::ApiError => fallback_error
        return handle_expected_merge_failure(
          project,
          pr_number,
          fallback_error,
          message: "dependabot_auto_merge.pat_fallback_failed",
          credential_mode: AutoMergeAttempt::CREDENTIAL_MODE_PAT_FALLBACK
        )
      end
    end

    handle_expected_merge_failure(
      project,
      pr_number,
      e,
      message: "dependabot_auto_merge.merge_failed_expected",
      credential_mode: AutoMergeAttempt.primary_credential_mode(project)
    )
  end

  def handle_expected_merge_failure(project, pr_number, error, message:, credential_mode:)
    raise unless expected_merge_failure?(error)

    if workflow_permission_rejection?(error)
      record_merge_permission_rejection(project, pr_number, error.message)
      post_merge_permission_comment(
        project,
        pr_number,
        fallback_attempted: credential_mode == AutoMergeAttempt::CREDENTIAL_MODE_PAT_FALLBACK
      )
    end
    record_attempt(
      project,
      pr_number,
      status: workflow_permission_rejection?(error) ? "blocked" : "failed",
      reason_code: workflow_permission_rejection?(error) ? AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION : AutoMergeAttempts::Record::REASON_EXPECTED_MERGE_FAILURE,
      message: error.message,
      credential_mode: credential_mode
    )

    Rails.logger.warn(
      message: message,
      project_id: project.id,
      pr_number: pr_number,
      status: error.status,
      error: error.message
    )
    false
  end

  def merge_dependabot_pr_with(client, project, pr_number, credential_mode:)
    client.merge_pull_request(
      project.full_name, pr_number,
      merge_method: project.merge_method
    )
    clear_merge_permission_rejection(project, pr_number)
    add_label(client, project, pr_number)
    add_comment(client, project, pr_number)

    Rails.logger.info(
      message: "dependabot_auto_merge.merged",
      project_id: project.id,
      pr_number: pr_number
    )
    record_attempt(
      project,
      pr_number,
      status: "merged",
      credential_mode: credential_mode
    )
    true
  end

  def workflow_permission_rejection?(error)
    return false if error.respond_to?(:status) && error.status != 403

    AgentRun::PUSH_PERMISSION_REJECTION_KEYWORDS.any? { |keyword| error.message.include?(keyword) }
  end

  def expected_merge_failure?(error)
    EXPECTED_MERGE_STATUSES.include?(error.status) || workflow_permission_rejection?(error)
  end

  def record_merge_permission_rejection(project, pr_number, reason)
    pull_request_issue(project, pr_number)&.record_merge_permission_rejection!(reason: reason)
  end

  def clear_merge_permission_rejection(project, pr_number)
    issue = pull_request_issue(project, pr_number)
    return unless issue&.merge_permission_rejected?

    issue.update!(merge_permission_rejected_at: nil, merge_permission_rejection_reason: nil)
  end

  def pull_request_issue(project, pr_number)
    project.issues.find_by(github_number: pr_number, is_pull_request: true)
  end

  def record_attempt(project, pr_number, **attributes)
    issue = pull_request_issue(project, pr_number)
    return unless issue

    AutoMergeAttempts::Record.call(project: project, issue: issue, actor_path: AutoMergeAttempts::Record::ACTOR_DEPENDABOT_AUTO_MERGE, **attributes)
  end

  def add_label(client, project, pr_number)
    Projects::EnsureStandardLabels.call_best_effort(project: project)
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

  def post_merge_permission_comment(project, pr_number, fallback_attempted:)
    AutoMergeAttempts::PostPermissionComment.call(
      project: project,
      pr_number: pr_number,
      marker: MERGE_PERMISSION_COMMENT_MARKER,
      title: "**Dependabot auto-merge blocked: missing GitHub App permission**",
      intro: "Paid could not auto-merge this Dependabot PR because the GitHub App installation token " \
        "lacks a permission needed for a change under `.github/workflows/` " \
        "(most commonly the `workflows` permission). This is permanent until " \
        "the App's permissions change, so Paid will keep checking periodically " \
        "rather than retrying every cycle.",
      fallback_attempted: fallback_attempted,
      logger: Rails.logger,
      log_component: "dependabot_auto_merge"
    )
  end
end
