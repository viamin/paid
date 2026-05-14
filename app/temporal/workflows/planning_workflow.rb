# frozen_string_literal: true

module Workflows
  # Decomposes a feature request (GitHub issue) into smaller, independently-implementable
  # sub-tasks using LLM analysis. Uses API mode (no container needed).
  #
  # Triggered by GitHubPollWorkflow when DetectLabelsActivity returns
  # action: "start_planning".
  #
  # Steps:
  # 1. Fetch the issue and project context
  # 2. Gather codebase knowledge via semantic search
  # 3. Decompose the feature into sub-tasks using LLM
  # 4. Create sub-issues in GitHub
  # 5. Update labels on the parent issue
  #
  # TODO(#694): Add a plan review/approval signal gate between steps 3 and 4
  # so stakeholders can review the decomposed plan before sub-issues are created.
  class PlanningWorkflow < BaseWorkflow
    NO_RETRY = Temporalio::RetryPolicy.new(max_attempts: 1)

    class << self
      def outcome_mappings
        {
          success: [
            planning_outcome_for([]),
            planning_outcome_for([ { title: "One task" } ]),
            planning_outcome_for([ { title: "Task one" }, { title: "Task two" } ])
          ].uniq,
          failure: {
            "decompose_feature" => planning_failure_outcome_for("decompose_feature"),
            "create_sub_issues" => planning_failure_outcome_for("create_sub_issues"),
            "update_planning_labels" => planning_failure_outcome_for("update_planning_labels")
          }
        }
      end

      def planning_outcome_for(tasks)
        return "empty_plan" if tasks.empty?
        return "single_task_plan" if tasks.one?

        "sub_issues_created"
      end

      def planning_failure_outcome_for(step)
        case step
        when "decompose_feature" then "decomposition_failed"
        when "create_sub_issues" then "sub_issue_creation_failed"
        else "planning_failed"
        end
      end
    end

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      workflow_id = Temporalio::Workflow.info.workflow_id

      Temporalio::Workflow.logger.info(
        "PlanningWorkflow started for project=#{project_id} issue=#{issue_id}"
      )

      context_result = {}
      tasks = []
      created_issues = []
      prompt_source = nil
      policy_metadata = {}
      decision_step = "fetch_planning_context"

      # Step 1: Fetch knowledge base context for informed decomposition
      context_result = run_activity(
        Activities::FetchPlanningContextActivity,
        { project_id: project_id, issue_id: issue_id },
        timeout: 60
      )

      # Step 2: Decompose the feature into sub-tasks using LLM
      decision_step = "decompose_feature"
      decompose_result = run_activity(
        Activities::DecomposeFeatureActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          knowledge_context: context_result[:context],
          workflow_name: self.class.name,
          workflow_id: workflow_id
        },
        timeout: 120
      )

      tasks = Array(decompose_result[:tasks])
      prompt_source = decompose_result[:prompt_source]
      policy_metadata = decomposition_policy_metadata(decompose_result)

      # Step 3: Create sub-issues from the plan (skip if single-task or empty)
      if tasks.present? && tasks.size > 1
        sub_tasks = tasks.map { |t| { title: t[:title], body: t[:description] } }

        decision_step = "create_sub_issues"
        create_result = run_activity(
          Activities::CreateSubIssuesActivity,
          {
            project_id: project_id,
            parent_issue_id: issue_id,
            sub_tasks: sub_tasks
          },
          timeout: 120,
          retry_policy: NO_RETRY
        )

        created_issues = create_result[:created_issues]
      end

      # Step 4: Update labels on the parent issue
      decision_step = "update_planning_labels"
      run_activity(
        Activities::UpdatePlanningLabelsActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size
        },
        timeout: 30
      )

      safe_log_decomposition_decision(
        project_id: project_id,
        issue_id: issue_id,
        decision_key: "#{workflow_id}:planning_outcome:final",
        workflow_name: self.class.name,
        workflow_id: workflow_id,
        decision_type: "planning_outcome",
        outcome: planning_outcome_for(tasks),
        input_context: context_result[:context],
        plan_data: {
          tasks: tasks,
          created_issues: created_issues
        },
        metadata: {
          prompt_source: prompt_source,
          **policy_metadata,
          failed_step: nil,
          activity_boundaries: %w[
            Activities::FetchPlanningContextActivity
            Activities::DecomposeFeatureActivity
            Activities::CreateSubIssuesActivity
            Activities::UpdatePlanningLabelsActivity
          ]
        }
      )

      {
        success: true,
        project_id: project_id,
        issue_id: issue_id,
        task_count: tasks.size,
        created_issues: created_issues
      }

    rescue => e
      policy_metadata = policy_metadata.presence || decomposition_policy_metadata_from_error(e)

      safe_log_decomposition_decision(
        project_id: project_id,
        issue_id: issue_id,
        decision_key: "#{workflow_id}:planning_outcome:failure",
        workflow_name: self.class.name,
        workflow_id: workflow_id,
        decision_type: "planning_outcome",
        outcome: planning_failure_outcome_for(decision_step),
        input_context: context_result[:context],
        plan_data: {
          tasks: tasks,
          created_issues: created_issues
        },
        error_details: {
          error_class: e.class.to_s,
          error_message: e.message
        },
        metadata: {
          prompt_source: prompt_source,
          **policy_metadata,
          failed_step: decision_step,
          activity_boundaries: %w[
            Activities::FetchPlanningContextActivity
            Activities::DecomposeFeatureActivity
            Activities::CreateSubIssuesActivity
            Activities::UpdatePlanningLabelsActivity
          ]
        }
      )

      Temporalio::Workflow.logger.error(
        message: "PlanningWorkflow failed",
        project_id: project_id,
        issue_id: issue_id,
        error_class: e.class.to_s,
        error: e.message
      )
      raise
    end

    private

    def planning_outcome_for(tasks)
      self.class.planning_outcome_for(tasks)
    end

    def planning_failure_outcome_for(step)
      self.class.planning_failure_outcome_for(step)
    end

    def safe_log_decomposition_decision(payload)
      run_activity(
        Activities::LogDecompositionDecisionActivity,
        payload,
        timeout: 30,
        retry_policy: NO_RETRY
      )
    rescue => log_error
      Temporalio::Workflow.logger.warn(
        message: "planning.decomposition_decision_log_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        error_class: log_error.class.to_s,
        error: log_error.message
      )
    end
  end
end
