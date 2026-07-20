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
  TARGETED_MIN_RUNS_FOR_EVOLUTION = QualityThreshold::DEFAULT_MIN_SAMPLE_SIZE

  def perform(project_id: nil, prompt_id: nil, recovery_action_id: nil, sample_days: SAMPLE_DAYS,
              failure_only: false, metric_type: "composite_score",
              threshold: PromptEvolution::SampleRuns::QUALITY_THRESHOLD, goal_type: nil)
    @project_id = project_id
    @prompt_id = prompt_id
    @sample_days = sample_days
    @failure_only = failure_only
    @metric_type = metric_type.presence || "composite_score"
    @threshold = threshold.to_f
    @goal_type = goal_type
    workflow_started = false
    eligible_prompt_found = false

    eligible_prompts.find_each do |prompt|
      eligible_prompt_found = true
      start_evolution_workflow(prompt, recovery_action_id: recovery_action_id, sample_days: sample_days)
      workflow_started = true
    rescue => e
      Rails.logger.warn(
        message: "prompt_evolution.job_failed_for_prompt",
        prompt_id: prompt.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    return unless recovery_action_id && !workflow_started
    return if track_running_recovery_test(recovery_action_id)

    reason = eligible_prompt_found ? "workflow_start_failed" : "no_eligible_prompt"
    fail_recovery_action(recovery_action_id, reason)
  end

  private

  attr_reader :project_id, :prompt_id, :sample_days, :failure_only, :metric_type, :threshold, :goal_type

  def eligible_prompts
    scope = Prompt
      .active
      .where.not(current_version_id: nil)
      .where.not(id: prompts_with_running_tests)
      .distinct

    if targeted?
      targeted_scope = scope.where(id: prompts_with_targeted_failures)
      targeted_scope = targeted_scope.where(id: prompt_id) if prompt_id
      targeted_scope
    else
      base = scope.where(id: prompts_with_sufficient_runs)
      base = base.where(id: prompt_id) if prompt_id
      base = base.where("project_id = ? OR project_id IS NULL", project_id) if project_id
      base
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
      .where(completed_at: sample_days.days.ago..)
      .where.not(prompt_version_id: nil)
      .joins(prompt_version: :prompt)
      .group("prompts.id")
      .having("COUNT(*) >= ?", MIN_RUNS_FOR_EVOLUTION)
      .select("prompts.id")
  end

  def prompts_with_targeted_failures
    scope = AgentRun
      .where(AgentRun.quality_scoreable_sql)
      .where(completed_at: sample_days.days.ago..)
      .where(project_id: project_id)
      .where.not(prompt_version_id: nil)
      .joins(:quality_metrics)
      .merge(QualityMetric.automated)
      .merge(QualityMetric.below_threshold(metric_type, threshold))
      .joins(prompt_version: :prompt)

    scope = scope.where(goal: goal_type) if goal_type.present?
    scope
      .group("prompts.id")
      .having("COUNT(DISTINCT agent_runs.id) >= ?", TARGETED_MIN_RUNS_FOR_EVOLUTION)
      .select("prompts.id")
  end

  def start_evolution_workflow(prompt, recovery_action_id: nil, sample_days: SAMPLE_DAYS)
    workflow_id = workflow_id_for(prompt, recovery_action_id)

    Paid.temporal_client.start_workflow(
      Workflows::PromptEvolutionWorkflow,
      workflow_input(prompt, recovery_action_id: recovery_action_id, sample_days: sample_days),
      id: workflow_id,
      task_queue: Paid.agent_task_queue
    )

    Rails.logger.info(
      message: "prompt_evolution.workflow_started",
      prompt_id: prompt.id,
      project_id: project_id || prompt.project_id,
      recovery_action_id: recovery_action_id,
      workflow_id: workflow_id
    )
  end

  def workflow_input(prompt, recovery_action_id: nil, sample_days: SAMPLE_DAYS)
    input = {
      prompt_id: prompt.id,
      project_id: project_id || prompt.project_id,
      sample_days: sample_days,
      recovery_action_id: recovery_action_id
    }

    return input unless failure_only

    input.merge(
      goal_type: goal_type,
      sample_size: TARGETED_SAMPLE_SIZE,
      failure_only: true,
      metric_type: metric_type,
      threshold: threshold,
      min_runs_for_evaluation: TARGETED_MIN_RUNS_FOR_EVOLUTION
    )
  end

  def workflow_id_for(prompt, recovery_action_id)
    return "quality-recovery-prompt-evolution-#{recovery_action_id}" if recovery_action_id
    return "prompt-evolution-quality-pause-#{project_id}-#{prompt.id}-#{goal_type.presence || 'all-goals'}-#{metric_type}-#{Date.current}" if targeted?

    "prompt-evolution-#{prompt.id}-#{Date.current}"
  end

  def fail_recovery_action(recovery_action_id, status)
    action = QualityRecoveryAction.find_by(id: recovery_action_id)
    return unless action

    action.fail!(status: status)
  end

  def track_running_recovery_test(recovery_action_id)
    action = QualityRecoveryAction.find_by(id: recovery_action_id)
    prompt = Prompt.find_by(id: prompt_id)
    ab_test = prompt&.ab_tests&.running&.first
    return false unless action && ab_test

    action.update!(result: { status: "already_running", ab_test_id: ab_test.id, prompt_id: prompt.id })
    true
  end
end
