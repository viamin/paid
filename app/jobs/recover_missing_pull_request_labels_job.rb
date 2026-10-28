# frozen_string_literal: true

# Re-applies missing labels to pull requests created by Paid when the
# original post-creation label API call failed transiently.
#
# If a PR still has the generated label but is missing the automation label,
# assume a human intentionally removed automation to take over manually and do
# not re-add it.
#
# Scheduled via GoodJob cron every hour. Only inspects recently terminal runs
# so query cost stays bounded as the table grows.
class RecoverMissingPullRequestLabelsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "recover_missing_pull_request_labels"
  )

  CANDIDATE_WINDOW = 30.days
  IDENTITY_RECOVERY_BACKOFF = 24.hours

  def perform
    recovered = 0
    skipped = 0
    failed = 0
    not_synced = 0

    runs = candidate_runs.to_a
    synced_prs = prefetch_synced_prs(runs)

    runs.each do |agent_run|
      # Upstream mode (#4078): never re-add labels to PRs opened in the
      # upstream repository. @spec UPSTREAM-GATE-002
      unless agent_run.project.upstream_feature_enabled?(:pr_labeling)
        skipped += 1
        next
      end

      agent_run = recover_pull_request_identity(agent_run)
      unless agent_run
        not_synced += 1
        next
      end

      synced_pr = synced_prs[[ agent_run.project_id, agent_run.pull_request_number ]] ||
        locally_synced_pr(agent_run)

      unless synced_pr
        synced_pr = backfill_synced_pr(agent_run)
        if synced_pr
          synced_prs[[ agent_run.project_id, agent_run.pull_request_number ]] = synced_pr
        else
          not_synced += 1
          next
        end
      end

      labels_to_recover = missing_labels(agent_run.project, synced_pr, agent_run)

      if labels_to_recover.empty?
        skipped += 1
        next
      end

      if recover_label(agent_run, synced_pr, labels_to_recover)
        recovered += 1
      else
        failed += 1
      end
    rescue => e
      failed += 1
      Rails.logger.error(
        message: "agent_execution.pr_label_recovery_unexpected_error",
        agent_run_id: agent_run.id,
        pr_number: agent_run.pull_request_number,
        error_class: e.class.name,
        error: e.message
      )
    end

    Rails.logger.info(
      message: "agent_execution.pr_label_recovery_complete",
      recovered: recovered,
      skipped: skipped,
      failed: failed,
      not_synced: not_synced
    )
  end

  private

  # Returns one AgentRun per recorded PR or branch identity. Terminal runs may
  # fail after GitHub accepts a PR but before its identity is persisted, so a
  # branch is a second, exact GitHub lookup key. The bounded window prevents a
  # historical full-table recovery scan.
  # DISTINCT ON deduplicates in SQL so we don't need an in-memory Set.
  # Uses the (status, completed_at) index.
  # @spec PR-LABEL-RECOVERY-001
  def candidate_runs # @spec PR-LABEL-RECOVERY-001 PR-LABEL-RECOVERY-003 UPSTREAM-PR-005
    AgentRun.joins(:project)
      .where(goal: "create_pr")
      .where(status: AgentRun::FINISHED_STATUSES)
      .where("COALESCE(agent_runs.completed_at, agent_runs.updated_at) >= ?", CANDIDATE_WINDOW.ago)
      .where("agent_runs.pull_request_number IS NOT NULL OR NULLIF(agent_runs.branch_name, '') IS NOT NULL")
      .where(
        "agent_runs.pull_request_number IS NOT NULL OR " \
          "agent_runs.pr_identity_recovery_attempted_at IS NULL OR " \
          "agent_runs.pr_identity_recovery_attempted_at <= ?",
        IDENTITY_RECOVERY_BACKOFF.ago
      )
      .where.not(projects: { pr_target: "upstream" })
      .select("DISTINCT ON (project_id, COALESCE(pull_request_number, 0), COALESCE(branch_name, '')) agent_runs.*")
      .order(Arel.sql("project_id, COALESCE(pull_request_number, 0), COALESCE(branch_name, ''), id DESC"))
      .preload(:issue, project: :github_token)
  end

  # Batch-loads synced Issue records for all candidate runs, keyed by
  # [project_id, pull_request_number]. Groups by project_id and queries
  # github_number values in bounded chunks to avoid building a single large
  # OR predicate in SQL.
  def prefetch_synced_prs(runs)
    pr_keys = runs.filter_map do |run|
      [ run.project_id, run.pull_request_number ] if run.pull_request_number.present?
    end.uniq

    return {} if pr_keys.empty?

    result = {}

    # Group by project_id so we can use a simple IN clause on github_number
    pr_keys.group_by(&:first).each do |project_id, pairs|
      numbers = pairs.map(&:second).uniq

      # Query in chunks to keep the IN list size bounded.
      numbers.each_slice(500) do |number_slice|
        Issue
          .where(is_pull_request: true, project_id: project_id, github_number: number_slice)
          .find_each do |issue|
            result[[ issue.project_id, issue.github_number ]] = issue
          end
      end
    end

    result
  end

  # @spec PR-LABEL-RECOVERY-002
  def missing_labels(project, synced_pr, agent_run)
    inherited_missing = inheritable_priority_labels(project, agent_run)
      .reject { |l| synced_pr.has_label?(l) }

    return inherited_missing unless project.auto_add_labels_enabled?

    generated = project.generated_label_name
    automation = project.automation_label_name

    if synced_pr.has_label?(generated)
      # Generated label is the marker that initial labeling succeeded; if
      # it is present we only need to backfill missing priority labels.
      return inherited_missing
    end

    labels = [ generated ]
    labels << automation unless synced_pr.has_label?(automation)
    labels.concat(inherited_missing)
    labels.uniq
  end

  def backfill_synced_pr(agent_run)
    project = agent_run.project
    github_issue = project.client.issue(project.full_name, agent_run.pull_request_number)
    Issues::UpsertFromGithub.call(project: project, github_issue: github_issue)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "agent_execution.pr_sync_recovery_failed",
      agent_run_id: agent_run.id,
      project_id: project.id,
      pr_number: agent_run.pull_request_number,
      error: e.message
    )
    nil
  end

  def locally_synced_pr(agent_run)
    Issue.find_by(
      project_id: agent_run.project_id,
      is_pull_request: true,
      github_number: agent_run.pull_request_number
    )
  end

  # @spec PR-LABEL-RECOVERY-003
  def recover_pull_request_identity(agent_run)
    return agent_run if agent_run.pull_request_number.present?
    return unless agent_run.branch_name.present?

    matches = agent_run.project.client.pull_requests(
      agent_run.project.full_name,
      state: "open",
      head: "#{agent_run.project.owner}:#{agent_run.branch_name}"
    )
    unless matches.one?
      mark_branch_identity_recovery_attempted(agent_run)
      return
    end

    pull_request = matches.first
    agent_run.update!(pull_request_number: pull_request.number, pull_request_url: pull_request.html_url)
    agent_run
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "agent_execution.pr_identity_recovery_failed",
      agent_run_id: agent_run.id,
      project_id: agent_run.project_id,
      error: e.message
    )
    nil
  end

  def mark_branch_identity_recovery_attempted(agent_run)
    AgentRun.where(
      project_id: agent_run.project_id,
      branch_name: agent_run.branch_name,
      pull_request_number: nil
    ).update_all(pr_identity_recovery_attempted_at: Time.current)
  end

  def inheritable_priority_labels(project, agent_run)
    return [] unless project.inherit_priority_labels?
    issue = agent_run.issue
    return [] if issue.blank? || issue.labels.blank?

    project.priority_labels_among(issue.labels)
  end

  def recover_label(agent_run, synced_pr, labels)
    project = agent_run.project

    project.client.add_labels_to_issue(
      project.full_name,
      agent_run.pull_request_number,
      labels
    )

    synced_pr.with_lock do
      synced_pr.update!(labels: (synced_pr.labels + labels).uniq)
    end

    Rails.logger.info(
      message: "agent_execution.pr_label_recovered",
      agent_run_id: agent_run.id,
      project_id: project.id,
      pr_number: agent_run.pull_request_number,
      labels: labels
    )

    true
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "agent_execution.pr_label_recovery_failed",
      agent_run_id: agent_run.id,
      project_id: project.id,
      pr_number: agent_run.pull_request_number,
      error: e.message
    )
    false
  end
end
