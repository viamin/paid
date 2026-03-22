# frozen_string_literal: true

require "set"

# Re-applies the `paid-generated` label to pull requests created by Paid when
# the original post-creation label API call failed transiently.
#
# Scheduled via GoodJob cron every 15 minutes.
class RecoverMissingPrLabelsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "recover_missing_pr_labels"
  )

  PAID_GENERATED_LABEL = "paid-generated"

  def perform
    recovered = 0
    skipped = 0
    failed = 0
    seen_prs = Set.new

    candidate_runs.find_each do |agent_run|
      pr_key = [ agent_run.project_id, agent_run.pull_request_number ]
      next unless seen_prs.add?(pr_key)

      if pr_labeled_locally?(agent_run)
        skipped += 1
        next
      end

      if recover_label(agent_run)
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
      failed: failed
    )
  end

  private

  def candidate_runs
    AgentRun.completed
      .where(goal: "create_pr")
      .where.not(pull_request_number: nil)
      .includes(project: :github_token)
      .order(:id)
  end

  def pr_labeled_locally?(agent_run)
    synced_pr = synced_pull_request(agent_run)
    synced_pr&.has_label?(PAID_GENERATED_LABEL)
  end

  def synced_pull_request(agent_run)
    agent_run.project.issues.find_by(
      github_number: agent_run.pull_request_number,
      is_pull_request: true
    )
  end

  def recover_label(agent_run)
    project = agent_run.project
    project.github_token.client.add_labels_to_issue(
      project.full_name,
      agent_run.pull_request_number,
      [ PAID_GENERATED_LABEL ]
    )

    synced_pr = synced_pull_request(agent_run)
    synced_pr&.update!(labels: (synced_pr.labels + [ PAID_GENERATED_LABEL ]).uniq)

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
