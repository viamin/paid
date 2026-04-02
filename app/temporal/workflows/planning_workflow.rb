# frozen_string_literal: true

module Workflows
  # Decomposes a feature request (GitHub issue) into smaller, independently-implementable
  # sub-tasks using LLM analysis. Uses API mode (no container needed).
  #
  # Steps:
  # 1. Fetch the issue and project context
  # 2. Gather codebase knowledge via semantic search
  # 3. Decompose the feature into sub-tasks using LLM
  # 4. Create sub-issues in GitHub
  # 5. Update labels on the parent issue
  class PlanningWorkflow < BaseWorkflow
    NO_RETRY = Temporalio::RetryPolicy.new(max_attempts: 1)

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]

      Temporalio::Workflow.logger.info(
        "PlanningWorkflow started for project=#{project_id} issue=#{issue_id}"
      )

      # Step 1: Fetch knowledge base context for informed decomposition
      context_result = run_activity(
        Activities::FetchPlanningContextActivity,
        { project_id: project_id, issue_id: issue_id },
        timeout: 60
      )

      # Step 2: Decompose the feature into sub-tasks using LLM
      decompose_result = run_activity(
        Activities::DecomposeFeatureActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          knowledge_context: context_result[:context]
        },
        timeout: 120
      )

      tasks = decompose_result[:tasks]

      # Step 3: Create sub-issues from the plan (skip if single-task or empty)
      if tasks.present? && tasks.size > 1
        create_result = run_activity(
          Activities::CreateSubIssuesActivity,
          {
            project_id: project_id,
            parent_issue_id: issue_id,
            tasks: tasks
          },
          timeout: 120,
          retry_policy: NO_RETRY
        )

        sub_issue_ids = create_result[:sub_issue_ids]
      else
        sub_issue_ids = []
      end

      # Step 4: Update labels on the parent issue
      run_activity(
        Activities::UpdatePlanningLabelsActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size
        },
        timeout: 30
      )

      {
        success: true,
        project_id: project_id,
        issue_id: issue_id,
        task_count: tasks.size,
        sub_issue_ids: sub_issue_ids
      }

    rescue => e
      Temporalio::Workflow.logger.error(
        message: "PlanningWorkflow failed",
        project_id: project_id,
        issue_id: issue_id,
        error_class: e.class.to_s,
        error: e.message
      )
      raise
    end
  end
end
