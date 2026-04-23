# frozen_string_literal: true

# Cron job that triggers prompt evolution workflows for eligible prompts.
#
# Runs weekly and evaluates each active prompt with sufficient run history.
# For each eligible prompt, starts a PromptEvolutionWorkflow via Temporal
# to sample runs, generate mutations, and create A/B tests.
#
# Skips prompts that already have a running A/B test or lack a current version.
class PromptEvolutionJob < ApplicationJob
  queue_as :maintenance

  # Minimum completed runs required in the lookback window before
  # a prompt is considered for evolution.
  MIN_RUNS_FOR_EVOLUTION = PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION

  # Default lookback window for sampling (days)
  SAMPLE_DAYS = 14
  TARGETED_SAMPLE_SIZE = QualityThreshold::DEFAULT_WINDOW_SIZE

  def perform(project_id: nil, failure_only: false, metric_type: "composite_score",
              threshold: PromptEvolution::SampleRuns::QUALITY_THRESHOLD, goal_type: nil,
              source: "scheduled")
    @project_id = project_id
    @failure_only = failure_only
    @metric_type = metric_type.presence || "composite_score"
    @threshold = threshold.to_f
    @goal_type = goal_type
    @source = source

    eligible_prompts.find_each do |prompt|
      start_evolution_workflow(prompt)
    rescue => e
      Rails.logger.warn(
        message: "prompt_evolution.job_failed_for_prompt",
        prompt_id: prompt.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end

  private

  attr_reader :project_id, :failure_only, :metric_type, :threshold, :goal_type, :source

  def eligible_prompts
    scope = Prompt
      .active
      .where.not(current_version_id: nil)
      .where.not(id: prompts_with_running_tests)
      .distinct

    if targeted?
      scope.where(id: prompts_with_targeted_failures)
    else
      scope.where(id: prompts_with_sufficient_runs)
    end
  end

  def targeted?
    project_id.present? && failure_only
  end

  def prompts_with_running_tests
    AbTest.running.select(:prompt_id)
  end

  def prompts_with_sufficient_runs
    AgentRun
      .completed
      .where(completed_at: SAMPLE_DAYS.days.ago..)
      .where.not(prompt_version_id: nil)
      .joins(prompt_version: :prompt)
      .group("prompts.id")
      .having("COUNT(*) >= ?", MIN_RUNS_FOR_EVOLUTION)
      .select("prompts.id")
  end

  def prompts_with_targeted_failures
    scope = AgentRun
      .completed
      .where(completed_at: SAMPLE_DAYS.days.ago..)
      .where(project_id: project_id)
      .where.not(prompt_version_id: nil)
      .joins(:quality_metrics)
      .merge(QualityMetric.automated)
      .joins(prompt_version: :prompt)

    scope = scope.where(goal: goal_type) if goal_type.present?
    failure_scope(scope).select("prompts.id").distinct
  end

  def failure_scope(scope)
    if metric_type == "composite_score"
      scope.where("quality_metrics.composite_score < ?", threshold)
    else
      scope
        .where("jsonb_exists(quality_metrics.scores, ?)", metric_type)
        .where("(quality_metrics.scores ->> ?)::float < ?", metric_type, threshold)
    end
  end

  def start_evolution_workflow(prompt)
    Paid.temporal_client.start_workflow(
      Workflows::PromptEvolutionWorkflow,
      workflow_input(prompt),
      id: workflow_id(prompt),
      task_queue: ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
    )

    Rails.logger.info(
      message: "prompt_evolution.workflow_started",
      prompt_id: prompt.id,
      project_id: workflow_project_id(prompt),
      source: source
    )
  end

  def workflow_input(prompt)
    input = {
      prompt_id: prompt.id,
      project_id: workflow_project_id(prompt),
      sample_days: SAMPLE_DAYS
    }

    return input unless targeted?

    input.merge(
      goal_type: goal_type,
      sample_size: TARGETED_SAMPLE_SIZE,
      failure_only: true,
      metric_type: metric_type,
      threshold: threshold,
      min_runs_for_evaluation: QualityThreshold::DEFAULT_MIN_SAMPLE_SIZE
    )
  end

  def workflow_project_id(prompt)
    project_id || prompt.project_id
  end

  def workflow_id(prompt)
    return "prompt-evolution-#{prompt.id}-#{Date.current}" unless targeted?

    "prompt-evolution-quality-pause-#{project_id}-#{prompt.id}-#{Date.current}"
  end
end
