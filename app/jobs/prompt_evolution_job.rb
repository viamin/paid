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

  def perform(project_id: nil, prompt_id: nil, recovery_action_id: nil, sample_days: SAMPLE_DAYS)
    @project_id = project_id
    @prompt_id = prompt_id
    @sample_days = sample_days
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

  attr_reader :project_id, :prompt_id

  def eligible_prompts
    scope = Prompt
      .active
      .where.not(current_version_id: nil)
      .where.not(id: prompts_with_running_tests)
      .where(id: prompts_with_sufficient_runs)
    scope = scope.where(id: prompt_id) if prompt_id
    scope = scope.where("project_id = ? OR project_id IS NULL", project_id) if project_id
    scope
  end

  def prompts_with_running_tests
    AbTest.running.select(:prompt_id)
  end

  def prompts_with_sufficient_runs
    AgentRun
      .completed
      .where(completed_at: @sample_days.days.ago..)
      .where.not(prompt_version_id: nil)
      .joins(prompt_version: :prompt)
      .group("prompts.id")
      .having("COUNT(*) >= ?", MIN_RUNS_FOR_EVOLUTION)
      .select("prompts.id")
  end

  def start_evolution_workflow(prompt, recovery_action_id: nil, sample_days: SAMPLE_DAYS)
    workflow_id = workflow_id_for(prompt, recovery_action_id)

    Paid.temporal_client.start_workflow(
      Workflows::PromptEvolutionWorkflow,
      {
        prompt_id: prompt.id,
        project_id: project_id || prompt.project_id,
        sample_days: sample_days,
        recovery_action_id: recovery_action_id
      },
      id: workflow_id,
      task_queue: ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
    )

    Rails.logger.info(
      message: "prompt_evolution.workflow_started",
      prompt_id: prompt.id,
      project_id: project_id || prompt.project_id,
      recovery_action_id: recovery_action_id,
      workflow_id: workflow_id
    )
  end

  def workflow_id_for(prompt, recovery_action_id)
    return "quality-recovery-prompt-evolution-#{recovery_action_id}" if recovery_action_id

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
