# frozen_string_literal: true

# One-time backfill for issues stranded in paid_state="analyzed" before
# analyze_issue workflows started enqueueing their own follow-up runs.
#
# Without this pass, legacy analyzed issues can remain stuck indefinitely:
# they are no longer eligible for auto-pick, and unchanged issues are not
# revisited by incremental sync.
class AnalyzeIssueFollowupBackfillJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "analyze_issue_followup_backfill"
  )

  CACHE_NAMESPACE = "analyze_issue_followup_backfill/v1"

  def perform
    return if completed?

    processed = 0

    eligible_projects.find_each do |project|
      next if project_backfilled?(project.id)
      next unless Issues::AutoPickProjectGate.call(project)

      backfill_project(project)
      mark_project_backfilled(project.id)
      processed += 1
    rescue => e
      Rails.logger.error(
        message: "analyze_issue_followup_backfill.project_failed",
        project_id: project.id,
        error: e.message
      )
    end

    remaining = remaining_project_ids
    mark_completed if remaining.empty?

    Rails.logger.info(
      message: "analyze_issue_followup_backfill.completed",
      processed_projects: processed,
      remaining_projects: remaining.size
    )
  end

  private

  def backfill_project(project)
    analyzed_issues_for(project).find_each do |issue|
      analysis_run = latest_completed_analysis_run_for(issue)
      next unless analysis_run

      followup_goal = followup_goal_for(analysis_run)
      next unless followup_goal

      Activities::CreateFollowupRunActivity.new.execute(
        agent_run_id: analysis_run.id,
        goal: followup_goal
      )
    end
  end

  def analyzed_issues_for(project)
    project.issues
      .where(github_state: "open", is_pull_request: false, paid_state: "analyzed")
      .where.not(
        id: project.agent_runs
          .where(status: AgentRun::UNFINISHED_STATUSES)
          .where.not(issue_id: nil)
          .select(:issue_id)
      )
  end

  def latest_completed_analysis_run_for(issue)
    issue.agent_runs
      .where(goal: "analyze_issue", status: "completed")
      .order(completed_at: :desc, id: :desc)
      .first
  end

  def followup_goal_for(agent_run)
    payload = parse_analysis_payload(agent_run)
    return unless payload&.key?("sufficient_context") || payload&.key?(:sufficient_context)

    sufficient_context = payload["sufficient_context"]
    sufficient_context = payload[:sufficient_context] if sufficient_context.nil?
    sufficient_context ? "create_pr" : "enhance_issue"
  rescue JSON::ParserError => e
    Rails.logger.warn(
      message: "analyze_issue_followup_backfill.invalid_payload",
      agent_run_id: agent_run.id,
      error: e.message
    )
    nil
  end

  def parse_analysis_payload(agent_run)
    raw = agent_run.agent_run_logs.stdout.recent.limit(1).pick(:content)
    return if raw.blank?

    JSON.parse(raw)
  end

  def completed?
    Rails.cache.read(completed_cache_key) == true
  end

  def mark_completed
    Rails.cache.write(completed_cache_key, true)
  end

  def project_backfilled?(project_id)
    Rails.cache.read(project_cache_key(project_id)) == true
  end

  def mark_project_backfilled(project_id)
    Rails.cache.write(project_cache_key(project_id), true)
  end

  def remaining_project_ids
    eligible_projects.each_with_object([]) do |project, remaining|
      next if project_backfilled?(project.id)

      remaining << project.id
    end
  end

  def eligible_projects
    Project.active.where(auto_pick_enabled: true, auto_enhance_enabled: true)
  end

  def completed_cache_key
    "#{CACHE_NAMESPACE}/completed"
  end

  def project_cache_key(project_id)
    "#{CACHE_NAMESPACE}/projects/#{project_id}"
  end
end
