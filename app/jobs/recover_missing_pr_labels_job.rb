# frozen_string_literal: true

# Re-applies the `paid-generated` label to pull requests created by Paid when
# the original post-creation label API call failed transiently.
#
# Scheduled via GoodJob cron every hour. Only inspects runs from the last 24
# hours so query cost stays bounded as the table grows.
class RecoverMissingPrLabelsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "recover_missing_pr_labels"
  )

  PAID_GENERATED_LABEL = "paid-generated"
  CANDIDATE_WINDOW = 24.hours

  def perform
    recovered = 0
    skipped = 0
    failed = 0
    not_synced = 0

    runs = candidate_runs.to_a
    synced_prs = prefetch_synced_prs(runs)

    runs.each do |agent_run|
      synced_pr = synced_prs[[ agent_run.project_id, agent_run.pull_request_number ]]

      unless synced_pr
        not_synced += 1
        next
      end

      if synced_pr.has_label?(PAID_GENERATED_LABEL)
        skipped += 1
        next
      end

      if recover_label(agent_run, synced_pr)
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

  # Returns one AgentRun per unique (project_id, pull_request_number),
  # bounded to the last 24 hours. DISTINCT ON deduplicates in SQL so we
  # don't need an in-memory Set.
  def candidate_runs
    AgentRun.completed
      .where(goal: "create_pr")
      .where.not(pull_request_number: nil)
      .where("agent_runs.created_at >= ?", CANDIDATE_WINDOW.ago)
      .select("DISTINCT ON (project_id, pull_request_number) agent_runs.*")
      .order(:project_id, :pull_request_number, id: :desc)
      .preload(project: :github_token)
  end

  # Batch-loads synced Issue records for all candidate runs in a single query,
  # keyed by [project_id, pull_request_number]. Eliminates N+1 lookups.
  def prefetch_synced_prs(runs)
    pr_keys = runs.map { |r| [ r.project_id, r.pull_request_number ] }.uniq

    return {} if pr_keys.empty?

    Issue
      .where(is_pull_request: true)
      .where(
        project_id: pr_keys.map(&:first),
        github_number: pr_keys.map(&:last)
      )
      .each_with_object({}) do |issue, hash|
        key = [ issue.project_id, issue.github_number ]
        hash[key] = issue if pr_keys.include?(key)
      end
  end

  def recover_label(agent_run, synced_pr)
    project = agent_run.project
    project.github_token.client.add_labels_to_issue(
      project.full_name,
      agent_run.pull_request_number,
      [ PAID_GENERATED_LABEL ]
    )

    synced_pr.update!(labels: (synced_pr.labels + [ PAID_GENERATED_LABEL ]).uniq)

    Rails.logger.info(
      message: "agent_execution.pr_label_recovered",
      agent_run_id: agent_run.id,
      project_id: project.id,
      pr_number: agent_run.pull_request_number
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
