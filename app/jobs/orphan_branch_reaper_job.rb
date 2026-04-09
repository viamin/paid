# frozen_string_literal: true

# Deletes remote branches left behind by AgentRuns that pushed a branch but
# never created a pull request — typically due to timeout, retry, or failure.
#
# Scheduled via GoodJob cron every hour. A 1-hour grace period prevents races
# with active workflows or the idempotent CreatePullRequestActivity recovery.
class OrphanBranchReaperJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "orphan_branch_reaper"
  )

  REAPABLE_STATUSES = %w[retried timeout failed].freeze
  GRACE_PERIOD = 1.hour

  def perform
    deleted = 0
    skipped = 0
    missing = 0
    errored = 0

    candidate_runs.find_each do |agent_run|
      result = reap_branch(agent_run)

      case result
      when :deleted then deleted += 1
      when :skipped then skipped += 1
      when :missing then missing += 1
      when :error   then errored += 1
      end
    end

    Rails.logger.info(
      message: "branch_reaper.completed",
      deleted: deleted,
      skipped: skipped,
      missing: missing,
      errored: errored
    )
  end

  private

  def candidate_runs
    AgentRun
      .where(status: REAPABLE_STATUSES)
      .where(pull_request_url: nil)
      .where.not(branch_name: [ nil, "" ])
      .where("agent_runs.updated_at < ?", GRACE_PERIOD.ago)
      .preload(project: :github_token)
  end

  def reap_branch(agent_run)
    client = agent_run.project.github_token&.client
    unless client
      Rails.logger.warn(
        message: "branch_reaper.no_github_token",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id
      )
      return :error
    end

    repo = agent_run.project.full_name
    branch = agent_run.branch_name

    unless remote_branch_exists?(client, repo, branch)
      return :missing
    end

    if open_pr_references_branch?(client, repo, agent_run.project.owner, branch)
      Rails.logger.info(
        message: "branch_reaper.skipped_open_pr",
        agent_run_id: agent_run.id,
        repo: repo,
        branch: branch
      )
      return :skipped
    end

    client.delete_ref(repo, "heads/#{branch}")

    Rails.logger.info(
      message: "branch_reaper.deleted",
      agent_run_id: agent_run.id,
      repo: repo,
      branch: branch
    )

    :deleted
  rescue GithubClient::Error => e
    Rails.logger.error(
      message: "branch_reaper.error",
      agent_run_id: agent_run.id,
      error_class: e.class.name,
      error: e.message
    )
    :error
  end

  def remote_branch_exists?(client, repo, branch)
    client.ref(repo, "heads/#{branch}")
    true
  rescue GithubClient::NotFoundError
    false
  end

  def open_pr_references_branch?(client, repo, owner, branch)
    prs = client.pull_requests(repo, state: "open", head: "#{owner}:#{branch}")
    prs.any?
  end
end
