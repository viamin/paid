# frozen_string_literal: true

module Workflows
  # End-to-end orchestration of a multi-agent feature implementation.
  #
  # Chains PlanningWorkflow's decomposition with ParallelAgentExecutionWorkflow's
  # parallel execution, providing a single entry point for the full lifecycle:
  #
  #   1. Decompose the feature into sub-tasks (planning)
  #   2. Create sub-issues in GitHub
  #   3. Launch parallel agents on all sub-tasks
  #   4. Detect and resolve conflicts
  #   5. Optionally aggregate into a single PR
  #
  # Triggered by GitHubPollWorkflow when the `feature_orchestration` feature flag
  # is enabled and a planning decision is made for a multi-component issue.
  #
  # Input:
  #   project_id: ID of the project
  #   issue_id: ID of the parent feature issue
  #   timeout_seconds: (optional) Overall timeout for parallel execution
  #   aggregate_pr: (optional) Whether to create an aggregated PR
  class FeatureOrchestrationWorkflow < BaseWorkflow
    DEFAULT_TIMEOUT_SECONDS = 7200

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      timeout_seconds = input.fetch(:timeout_seconds, DEFAULT_TIMEOUT_SECONDS)

      Temporalio::Workflow.logger.info(
        message: "feature_orchestration.started",
        project_id: project_id,
        issue_id: issue_id
      )

      # Phase 1: Decompose the feature into sub-tasks
      planning_result = run_planning(project_id, issue_id)

      tasks = planning_result[:tasks] || []
      created_issues = planning_result[:created_issues]

      # Update labels/state immediately after planning completes (mirrors PlanningWorkflow step 4)
      run_activity(
        Activities::UpdatePlanningLabelsActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size
        },
        timeout: 30
      )

      # If planning produced 0-1 tasks, no parallel execution needed
      unless tasks.size > 1
        Temporalio::Workflow.logger.info(
          message: "feature_orchestration.single_task_skip",
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size
        )
        return {
          success: true,
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size,
          parallel_execution: false
        }
      end

      # Phase 2: Launch parallel execution on all sub-tasks
      sub_tasks = build_sub_tasks(tasks, created_issues)

      parallel_result = run_parallel_execution(
        project_id: project_id,
        issue_id: issue_id,
        sub_tasks: sub_tasks,
        timeout_seconds: timeout_seconds,
        aggregate_pr: input[:aggregate_pr]
      )

      Temporalio::Workflow.logger.info(
        message: "feature_orchestration.completed",
        project_id: project_id,
        issue_id: issue_id,
        completed: parallel_result[:completed],
        failed: parallel_result[:failed]
      )

      {
        success: parallel_result[:success],
        project_id: project_id,
        issue_id: issue_id,
        task_count: tasks.size,
        parallel_execution: true,
        completed: parallel_result[:completed],
        failed: parallel_result[:failed],
        conflicts: parallel_result[:conflicts],
        aggregated_pr: parallel_result[:aggregated_pr]
      }
    rescue => e
      Temporalio::Workflow.logger.error(
        message: "feature_orchestration.failed",
        project_id: project_id,
        issue_id: issue_id,
        error_class: e.class.to_s,
        error: e.message
      )
      raise
    end

    private

    # Inline planning steps (mirrors PlanningWorkflow) rather than invoking it as a child
    # workflow because orchestration needs direct access to the decomposed tasks and created
    # issues to build sub_tasks for parallel execution. A child workflow would only return a
    # summary, requiring re-fetching. Shared activities keep the actual logic deduplicated.
    def run_planning(project_id, issue_id)
      # Step 1: Fetch knowledge base context
      context_result = run_activity(
        Activities::FetchPlanningContextActivity,
        { project_id: project_id, issue_id: issue_id },
        timeout: 60
      )

      # Step 2: Decompose into sub-tasks
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
      created_issues = []

      # Step 3: Create sub-issues if multiple tasks
      if tasks.present? && tasks.size > 1
        create_result = run_activity(
          Activities::CreateSubIssuesActivity,
          {
            project_id: project_id,
            parent_issue_id: issue_id,
            sub_tasks: tasks.map { |t| { title: t[:title], body: t[:description] } }
          },
          timeout: 120,
          retry_policy: Temporalio::RetryPolicy.new(max_attempts: 1)
        )

        created_issues = create_result[:created_issues]
      end

      { tasks: tasks, created_issues: created_issues }
    end

    def build_sub_tasks(tasks, created_issues)
      tasks.each_with_index.map do |task, index|
        sub_task = {
          custom_prompt: task[:description],
          task_index: task.fetch(:index, index),
          dependencies: Array(task[:dependencies]),
          parallel_group: task[:parallel_group]
        }

        # Link to created issue — require a valid issue_id since downstream
        # workflows (AgentExecutionWorkflow) depend on it for state tracking.
        if created_issues[index]
          issue_id = created_issues[index][:issue_id]
          unless issue_id
            raise Temporalio::Error::ApplicationError.new(
              "CreateSubIssuesActivity returned nil issue_id for task #{index}: #{task[:title]}",
              type: "InvalidSubIssue",
              non_retryable: true
            )
          end
          sub_task[:issue_id] = issue_id
        end

        sub_task
      end
    end

    def run_parallel_execution(project_id:, issue_id:, sub_tasks:, timeout_seconds:, aggregate_pr:)
      parent_wf_id = Temporalio::Workflow.info.workflow_id

      child_input = {
        project_id: project_id,
        sub_tasks: sub_tasks,
        parent_workflow_id: parent_wf_id,
        parent_issue_id: issue_id,
        timeout_seconds: timeout_seconds
      }
      child_input[:aggregate_pr] = aggregate_pr unless aggregate_pr.nil?

      workflow_id = "parallel-#{parent_wf_id}-#{Temporalio::Workflow.now.to_i}"

      Temporalio::Workflow.execute_child_workflow(
        Workflows::ParallelAgentExecutionWorkflow,
        child_input,
        id: workflow_id,
        execution_timeout: timeout_seconds + 300,
        task_queue: Paid::AGENT_TASK_QUEUE
      )
    end
  end
end
