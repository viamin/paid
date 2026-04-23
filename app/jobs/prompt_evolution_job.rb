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

  def perform(prompt_id: nil, project_id: nil)
    return perform_targeted(prompt_id:, project_id:) if prompt_id.present?

    eligible_prompts.find_each do |prompt|
      start_evolution_workflow(prompt, project_id: prompt.project_id)
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

  def perform_targeted(prompt_id:, project_id:)
    prompt = Prompt.active.find_by(id: prompt_id, project_id: [ project_id, nil ])
    return if prompt.blank? || prompt.current_version_id.blank? || running_test?(prompt)

    start_evolution_workflow(prompt, project_id:)
  end

  def eligible_prompts
    Prompt
      .active
      .where.not(current_version_id: nil)
      .where.not(id: prompts_with_running_tests)
      .where(id: prompts_with_sufficient_runs)
  end

  def prompts_with_running_tests
    AbTest.running.select(:prompt_id)
  end

  def running_test?(prompt)
    AbTest.running.exists?(prompt_id: prompt.id)
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

  def start_evolution_workflow(prompt, project_id:)
    Paid.temporal_client.start_workflow(
      Workflows::PromptEvolutionWorkflow,
      {
        prompt_id: prompt.id,
        project_id: project_id,
        sample_days: SAMPLE_DAYS
      },
      id: "prompt-evolution-#{prompt.id}-#{Date.current}",
      task_queue: ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
    )

    Rails.logger.info(
      message: "prompt_evolution.workflow_started",
      prompt_id: prompt.id,
      project_id: prompt.project_id
    )
  end
end
