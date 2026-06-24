# frozen_string_literal: true

# Deletes remote branches left behind by AgentRuns that pushed a branch but
# never created a pull request — typically because the run was retried,
# timed out, or failed after push but before PR creation.
#
# The job is idempotent: re-running is a no-op once branches are gone.
# A one-hour grace period prevents racing with active workflows or with
# the idempotent CreatePullRequestActivity recovery on still-retrying runs.
#
# Scheduled via GoodJob cron every hour.
class OrphanBranchReaperJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "orphan_branch_reaper"
  )

  # How long after an AgentRun's last update before we consider its branch
  # eligible for reaping. Prevents racing with active workflows and with
  # the idempotent CreatePullRequestActivity retry path (#965).
  GRACE_PERIOD = 1.hour

  # Only inspect runs from the last 30 days to keep the query bounded.
  CANDIDATE_WINDOW = 30.days

  REAPABLE_STATUSES = %w[retried timeout token_budget_exceeded failed].freeze

  def perform
    job_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deleted = 0
    skipped = 0
    missing = 0
    errored = 0

    candidate_runs.find_each do |agent_run|
      result = reap_branch(agent_run)

      case result
      when :deleted  then deleted += 1
      when :skipped  then skipped += 1
      when :missing  then missing += 1
      when :errored  then errored += 1
      end
    rescue => e
      errored += 1
      Rails.logger.error(
        message: "branch_reaper.unexpected_error",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - job_started_at) * 1000).round
    Rails.logger.info(
      message: "branch_reaper.completed",
      deleted: deleted,
      skipped: skipped,
      missing: missing,
      errored: errored,
      duration_ms: duration_ms
    )
  end

  private

  # AgentRuns that pushed a branch but never opened a PR, in a terminal
  # failure state, and past the grace period.
  def candidate_runs
    AgentRun
      .where(status: REAPABLE_STATUSES)
      .where.not(branch_name: [ nil, "" ])
      .where(pull_request_url: [ nil, "" ])
      .where("agent_runs.updated_at < ?", GRACE_PERIOD.ago)
      .where("agent_runs.created_at >= ?", CANDIDATE_WINDOW.ago)
      .preload(project: :github_token)
  end

  def reap_branch(agent_run)
    project = agent_run.project
    token = project&.github_token

    unless token
      Rails.logger.warn(
        message: "branch_reaper.missing_token",
        agent_run_id: agent_run.id,
        project_id: project&.id
      )
      return :errored
    end

    client = token.client
    repo = project.full_name
    branch_name = agent_run.branch_name

    # Check whether the branch still exists on the remote.
    unless remote_branch_exists?(client, repo, branch_name)
      return :missing
    end

    # Never delete a branch that has any open PR referencing it.
    # Note: there is a small TOCTOU window between this check and delete_ref
    # below — a PR could be opened after we check. The 1-hour grace period
    # makes this very unlikely, and the worst case is deleting a branch whose
    # PR will then show as "branch deleted" on GitHub.
    if open_pr_exists?(client, repo, project.owner, branch_name)
      Rails.logger.info(
        message: "branch_reaper.skipped_open_pr",
        agent_run_id: agent_run.id,
        project_id: project.id,
        branch_name: branch_name
      )
      return :skipped
    end

    client.delete_ref(repo, "heads/#{branch_name}")

    Rails.logger.info(
      message: "branch_reaper.branch_deleted",
      agent_run_id: agent_run.id,
      project_id: project.id,
      branch_name: branch_name
    )

    :deleted
  rescue GithubClient::NotFoundError
    # Branch was deleted between our check and the delete call — idempotent.
    :missing
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "branch_reaper.delete_failed",
      agent_run_id: agent_run.id,
      project_id: project.id,
      branch_name: branch_name,
      error: e.message
    )
    :errored
  end

  def remote_branch_exists?(client, repo, branch_name)
    client.ref(repo, "heads/#{branch_name}")
    true
  rescue GithubClient::NotFoundError
    false
  end

  def open_pr_exists?(client, repo, owner, branch_name)
    prs = client.pull_requests(repo, state: "open", head: "#{owner}:#{branch_name}")
    prs.any?
  end
end
