# frozen_string_literal: true

module Workflows
  # Orchestrates the knowledge evolution cycle for a single project:
  #
  # 1. Sample recent enhance_issue runs and gather usage data
  # 2. Analyze knowledge gaps via LLM
  # 3. Persist actionable recommendations
  #
  # Triggered by KnowledgeEvolutionJob on a weekly schedule,
  # or manually via Temporal client for a specific project.
  #
  # Input:
  #   project_id:    - ID of the project to analyze
  #   lookback_days: - Days to look back for sampling (default: 14)
  class KnowledgeEvolutionWorkflow < BaseWorkflow
    SAMPLE_TIMEOUT = 60
    RECORD_TIMEOUT = 30

    def execute(input)
      project_id = input[:project_id]
      lookback_days = input.fetch(:lookback_days, 14)

      Temporalio::Workflow.logger.info(
        "KnowledgeEvolutionWorkflow started for project=#{project_id}"
      )

      # Step 1: Sample recent enhance_issue runs
      sample_result = run_activity(
        Activities::SampleEnhanceRunsActivity,
        { project_id: project_id, lookback_days: lookback_days },
        timeout: SAMPLE_TIMEOUT
      )

      if sample_result[:runs].blank?
        Temporalio::Workflow.logger.info(
          "KnowledgeEvolutionWorkflow: no enhance_issue data for project=#{project_id}"
        )
        return { status: :no_data, project_id: project_id }
      end

      # Step 2: Analyze knowledge gaps via LLM
      analysis_result = run_activity(
        Activities::AnalyzeKnowledgeGapsActivity,
        {
          project_id: project_id,
          sampled_runs: sample_result[:runs],
          artifact_usage: sample_result[:artifact_usage]
        },
        timeout: LLM_ACTIVITY_TIMEOUT,
        heartbeat_timeout: DEFAULT_HEARTBEAT_TIMEOUT
      )

      if analysis_result[:recommendations].blank?
        Temporalio::Workflow.logger.info(
          "KnowledgeEvolutionWorkflow: no knowledge gaps found for project=#{project_id}"
        )
        return { status: :no_gaps, project_id: project_id }
      end

      # Step 3: Persist recommendations
      record_result = run_activity(
        Activities::RecordKnowledgeRecommendationsActivity,
        {
          project_id: project_id,
          recommendations: analysis_result[:recommendations]
        },
        timeout: RECORD_TIMEOUT
      )

      {
        status: :completed,
        project_id: project_id,
        recommendations_created: record_result[:created_count],
        recommendations_dismissed: record_result[:dismissed_count]
      }
    rescue => e
      raise_if_canceled!(e)
      Temporalio::Workflow.logger.error(
        message: "KnowledgeEvolutionWorkflow failed",
        project_id: input[:project_id],
        error_class: e.class.to_s,
        error: e.message
      )
      raise
    end
  end
end
