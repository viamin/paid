# frozen_string_literal: true

# Shared CI-status verification logic for auto-merge jobs.
#
# Including classes must define +ci_log_component+ (e.g. "dependabot_auto_merge"
# or "auto_release") so log messages are attributed to the correct subsystem.
module CiStatusVerification
  extend ActiveSupport::Concern

  private

  # Override in the including class to set the log-message prefix.
  def ci_log_component
    raise NotImplementedError, "#{self.class} must define #ci_log_component"
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
      message: "#{ci_log_component}.check_runs_forbidden",
      project_id: project.id,
      error: e.message
    )
    workflow_runs_or_status_green?(client, project, sha)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "#{ci_log_component}.check_runs_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  def all_checks_green!(client, project, pr_data)
    sha = pr_data.respond_to?(:head) ? pr_data.head.sha : pr_data.dig(:head, :sha)
    checks = client.check_runs_for_ref(project.full_name, sha)

    if checks.nil? || checks.empty?
      return combined_status_ok!(client, project, sha, strict: false)
    end

    conclusions_green?(checks)
  rescue GithubClient::ApiError => e
    raise unless e.status == 403

    Rails.logger.info(
      message: "#{ci_log_component}.check_runs_forbidden",
      project_id: project.id,
      error: e.message
    )
    workflow_runs_or_status_green!(client, project, sha)
  end

  # Reached when the Checks API is forbidden (e.g., fine-grained tokens have
  # no Checks permission). Verifies CI via the Actions API instead. If Actions
  # is also unavailable or empty, only an explicit "success" combined status
  # passes — "pending + 0 contexts" is not safe here because we never confirmed
  # the absence of check runs from non-Actions GitHub Apps.
  def workflow_runs_or_status_green?(client, project, sha)
    runs = client.workflow_runs_for_sha(project.full_name, sha)
    return workflow_runs_and_statuses_green?(client, project, sha, runs) if runs.any?

    combined_status_ok?(client, project, sha, strict: true)
  rescue GithubClient::ApiError => e
    raise unless e.status == 403

    Rails.logger.info(
      message: "#{ci_log_component}.workflow_runs_forbidden",
      project_id: project.id,
      error: e.message
    )
    combined_status_ok?(client, project, sha, strict: true)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "#{ci_log_component}.workflow_runs_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  def workflow_runs_or_status_green!(client, project, sha)
    runs = client.workflow_runs_for_sha(project.full_name, sha)
    return workflow_runs_and_statuses_green!(client, project, sha, runs) if runs.any?

    combined_status_ok!(client, project, sha, strict: true)
  rescue GithubClient::ApiError => e
    raise unless e.status == 403

    Rails.logger.info(
      message: "#{ci_log_component}.workflow_runs_forbidden",
      project_id: project.id,
      error: e.message
    )
    combined_status_ok!(client, project, sha, strict: true)
  end

  # When Actions runs are available, they prove GitHub Actions is green but do
  # not cover third-party CI providers that only publish commit-status
  # contexts. Consult combined_status as an additional gate when possible so a
  # failing status context still blocks the merge. "pending + 0 contexts" means
  # no status-based CI was reported, so green workflow runs remain sufficient.
  def workflow_runs_and_statuses_green?(client, project, sha, runs)
    conclusions_green?(runs) && combined_status_ok?(client, project, sha, strict: false, allow_forbidden: true)
  end

  def workflow_runs_and_statuses_green!(client, project, sha, runs)
    conclusions_green?(runs) && combined_status_ok!(client, project, sha, strict: false, allow_forbidden: true)
  end

  def conclusions_green?(items)
    items.all? { |i| %w[success skipped neutral].include?(i[:conclusion]) }
  end

  # When +strict+ is false, "pending + 0 contexts" counts as "no CI configured"
  # and allows the merge — safe only when the caller has positive evidence (an
  # empty check_runs response) that no check runs exist either. When +strict+
  # is true (e.g., the Checks API was forbidden), only an explicit "success"
  # passes, since absence of statuses cannot prove absence of check runs.
  def combined_status_ok?(client, project, sha, strict:, allow_forbidden: false)
    status = client.combined_status(project.full_name, sha)
    return true if status[:state] == "success"
    !strict && status[:state] == "pending" && status[:total_count] == 0
  rescue GithubClient::ApiError => e
    if allow_forbidden && e.status == 403
      Rails.logger.info(
        message: "#{ci_log_component}.combined_status_forbidden",
        project_id: project.id,
        error: e.message
      )
      return true
    end

    Rails.logger.warn(
      message: "#{ci_log_component}.combined_status_failed",
      project_id: project.id,
      error: e.message
    )
    false
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "#{ci_log_component}.combined_status_failed",
      project_id: project.id,
      error: e.message
    )
    false
  end

  def combined_status_ok!(client, project, sha, strict:, allow_forbidden: false)
    status = client.combined_status(project.full_name, sha)
    return true if status[:state] == "success"
    !strict && status[:state] == "pending" && status[:total_count] == 0
  rescue GithubClient::ApiError => e
    if allow_forbidden && e.status == 403
      Rails.logger.info(
        message: "#{ci_log_component}.combined_status_forbidden",
        project_id: project.id,
        error: e.message
      )
      return true
    end

    raise
  end
end
