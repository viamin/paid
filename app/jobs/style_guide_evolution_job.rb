# frozen_string_literal: true

class StyleGuideEvolutionJob < ApplicationJob
  queue_as :maintenance

  SAMPLE_DAYS = StyleGuideEvolution::SampleRuns::DEFAULT_DAYS

  # @spec STYLE-GUIDE-EVOLUTION-009
  def perform(project_id: nil, style_guide_id: nil, sample_days: SAMPLE_DAYS)
    eligible_style_guides(project_id:, style_guide_id:, sample_days:).find_each do |style_guide|
      Paid.temporal_client.start_workflow(
        Workflows::StyleGuideEvolutionWorkflow,
        {
          style_guide_id: style_guide.id,
          project_id: project_id || style_guide.project_id,
          sample_days: sample_days
        },
        id: workflow_id_for(style_guide, project_id),
        task_queue: ENV.fetch("TEMPORAL_TASK_QUEUE", "paid-tasks")
      )
    rescue => error
      Rails.logger.warn(
        message: "style_guide_evolution.job_failed_for_style_guide",
        style_guide_id: style_guide.id,
        error_class: error.class.name,
        error: error.message
      )
    end
  end

  private

  def eligible_style_guides(project_id:, style_guide_id:, sample_days:)
    accounts_with_running_tests = StyleGuideAbTest.running.where.not(account_id: nil).select(:account_id)

    scope = StyleGuide.active
      .where.not(current_version_id: nil)
      .where.not(account_id: nil, project_id: nil)
      # WHERE NOT (account_id IS NULL AND project_id IS NULL)
      # → account_id IS NOT NULL OR project_id IS NOT NULL
      # This includes both account-level guides (account_id set, project_id nil)
      # and project-level guides (both set). Only global guides (both nil) are excluded.
      .where.not(id: StyleGuideAbTest.running.select(:style_guide_id))
      .where.not(account_id: accounts_with_running_tests)
      .joins(:style_guide_run_exposures)
      .where(style_guide_run_exposures: { created_at: sample_days.days.ago.. })
      .distinct
    scope = scope.where(id: style_guide_id) if style_guide_id
    scope = scope.where(project_id: project_id) if project_id
    scope
  end

  def workflow_id_for(style_guide, project_id)
    "style-guide-evolution-#{project_id || style_guide.project_id || style_guide.account_id}-#{style_guide.id}-#{Date.current}"
  end
end
