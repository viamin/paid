# frozen_string_literal: true

# Weekly cron job that triggers knowledge evolution workflows for eligible projects.
#
# Finds projects with knowledge_evolution_enabled and sufficient enhance_issue
# run history, then starts a KnowledgeEvolutionWorkflow per eligible project
# to sample runs, analyze knowledge gaps, and persist recommendations.
class KnowledgeEvolutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :knowledge

  good_job_control_concurrency_with(total_limit: 1)

  # Minimum completed enhance_issue runs in the lookback window
  MIN_ENHANCE_RUNS = 5

  # Lookback window for sampling (days)
  LOOKBACK_DAYS = 14

  def perform(project_id: nil)
    @project_id = project_id

    eligible_projects.find_each do |project|
      start_evolution_workflow(project)
    rescue => e
      Rails.logger.warn(
        message: "knowledge_evolution.job_failed_for_project",
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end

  private

  attr_reader :project_id

  def eligible_projects
    scope = Project
      .where(knowledge_evolution_enabled: true)
      .where(id: projects_with_sufficient_enhance_runs)

    scope = scope.where(id: project_id) if project_id
    scope
  end

  def projects_with_sufficient_enhance_runs
    AgentRun
      .where(status: "completed")
      .where(goal: "enhance_issue")
      .where(completed_at: LOOKBACK_DAYS.days.ago..)
      .group(:project_id)
      .having("COUNT(*) >= ?", MIN_ENHANCE_RUNS)
      .select(:project_id)
  end

  def start_evolution_workflow(project)
    workflow_id = "knowledge-evolution-#{project.id}-#{Date.current}"

    Paid.temporal_client.start_workflow(
      Workflows::KnowledgeEvolutionWorkflow,
      { project_id: project.id, lookback_days: LOOKBACK_DAYS },
      id: workflow_id,
      task_queue: ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
    )

    Rails.logger.info(
      message: "knowledge_evolution.workflow_started",
      project_id: project.id,
      workflow_id: workflow_id
    )
  end
end
