# frozen_string_literal: true

# Re-applies missing labels to pull requests created by Paid when the
# original post-creation label API call failed transiently.
#
# If a PR still has the generated label but is missing the automation label,
# assume a human intentionally removed automation to take over manually and do
# not re-add it.
#
# Scheduled via GoodJob cron every hour. Only inspects runs completed in the
# last 24 hours so query cost stays bounded as the table grows.
class RecoverMissingPullRequestLabelsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "recover_missing_pull_request_labels"
  )

  CANDIDATE_WINDOW = 24.hours
  Candidate = Data.define(:agent_run, :pull_request_number)

  def perform
    recovered = 0
    skipped = 0
    failed = 0
    not_synced = 0

    candidates = recovery_candidates
    synced_prs = prefetch_synced_prs(candidates)

    candidates.each do |candidate|
      agent_run = candidate.agent_run
      pull_request_number = candidate.pull_request_number
      # Upstream mode (#4078): never re-add labels to PRs opened in the
      # upstream repository. @spec UPSTREAM-GATE-002
      unless agent_run.project.upstream_feature_enabled?(:pr_labeling)
        skipped += 1
        next
      end

      synced_pr = synced_prs[[ agent_run.project_id, pull_request_number ]]

      unless synced_pr
        synced_pr = backfill_synced_pr(agent_run, pull_request_number)
        if synced_pr
          synced_prs[[ agent_run.project_id, pull_request_number ]] = synced_pr
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

      if recover_label(agent_run, synced_pr, labels_to_recover, pull_request_number)
        recovered += 1
      else
        failed += 1
      end
    rescue => e
      failed += 1
      Rails.logger.error(
        message: "agent_execution.pr_label_recovery_unexpected_error",
        agent_run_id: agent_run.id,
        pr_number: pull_request_number,
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

  # @spec PR-LABEL-RECOVERY-001 PR-LABEL-RECOVERY-003
  def candidate_runs # @spec PR-LABEL-RECOVERY-001 UPSTREAM-PR-005
    AgentRun.joins(:project)
      .where(goal: "create_pr")
      .where(status: AgentRun::FINISHED_STATUSES)
      .where("agent_runs.completed_at >= ?", CANDIDATE_WINDOW.ago)
      .where.not(projects: { pr_target: "upstream" })
      .order(id: :desc)
      .preload(:issue, project: :github_token)
  end

  # A run can publish a PR and then time out before recording its number.
  # The locally synced PR's parent source link is trusted project evidence, so
  # it supplies a bounded recovery path without guessing from PR text or
  # restoring labels on unrelated repository PRs.
  # @spec PR-LABEL-RECOVERY-003
  def recovery_candidates
    runs = candidate_runs.to_a
    linked_prs = linked_pull_requests(runs)
    candidates = runs.filter_map do |run|
      number = run.pull_request_number || linked_prs[[ run.project_id, run.issue_id ]]&.github_number
      Candidate.new(agent_run: run, pull_request_number: number) if number
    end

    candidates.uniq { |candidate| [ candidate.agent_run.project_id, candidate.pull_request_number ] }
  end

  def linked_pull_requests(runs)
    source_ids_by_project = runs.filter_map do |run|
      [ run.project_id, run.issue_id ] if run.pull_request_number.nil? && run.issue_id
    end.group_by(&:first)

    source_ids_by_project.each_with_object({}) do |(project_id, pairs), result|
      pairs.map(&:second).uniq.each_slice(500) do |source_ids|
        Issue.where(project_id:, parent_issue_id: source_ids, is_pull_request: true, github_state: "open").find_each do |pull_request|
          result[[ project_id, pull_request.parent_issue_id ]] ||= pull_request
        end
      end
    end
  end

  # Batch-loads synced Issue records for all candidate runs, keyed by
  # [project_id, pull_request_number]. Groups by project_id and queries
  # github_number values in bounded chunks to avoid building a single large
  # OR predicate in SQL.
  def prefetch_synced_prs(candidates)
    pr_keys = candidates.map { |candidate| [ candidate.agent_run.project_id, candidate.pull_request_number ] }.uniq

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

  def backfill_synced_pr(agent_run, pull_request_number)
    project = agent_run.project
    github_issue = project.client.issue(project.full_name, pull_request_number)
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

  def inheritable_priority_labels(project, agent_run)
    return [] unless project.inherit_priority_labels?
    issue = agent_run.issue
    return [] if issue.blank? || issue.labels.blank?

    project.priority_labels_among(issue.labels)
  end

  def recover_label(agent_run, synced_pr, labels, pull_request_number)
    project = agent_run.project

    project.client.add_labels_to_issue(
      project.full_name,
      pull_request_number,
      labels
    )

    synced_pr.with_lock do
      synced_pr.update!(labels: (synced_pr.labels + labels).uniq)
    end

    Rails.logger.info(
      message: "agent_execution.pr_label_recovered",
      agent_run_id: agent_run.id,
      project_id: project.id,
      pr_number: pull_request_number,
      labels: labels
    )

    true
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "agent_execution.pr_label_recovery_failed",
      agent_run_id: agent_run.id,
      project_id: project.id,
      pr_number: pull_request_number,
      error: e.message
    )
    false
  end
end
