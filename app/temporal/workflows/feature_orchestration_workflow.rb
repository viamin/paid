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
    NO_RETRY = Temporalio::RetryPolicy.new(max_attempts: 1)

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      timeout_seconds = input.fetch(:timeout_seconds, DEFAULT_TIMEOUT_SECONDS)
      workflow_id = Temporalio::Workflow.info.workflow_id
      workflow_started_at = Temporalio::Workflow.now

      Temporalio::Workflow.logger.info(
        message: "feature_orchestration.started",
        project_id: project_id,
        issue_id: issue_id
      )

      tasks = []
      created_issues = []
      parallel_result = nil
      planning_context = {}
      prompt_source = nil
      coordination_policy = nil
      coordination_assignment_id = nil
      scaling_execution_plan = nil
      scaling_assignment_id = nil
      decision_phase = "planning"
      decision_step = "fetch_planning_context"
      @decision_step = decision_step

      experiment_context = safely_resolve_coordination_experiment(
        project_id: project_id,
        issue_id: issue_id,
        workflow_id: workflow_id
      )
      coordination_policy = experiment_context[:coordination_policy]
      coordination_assignment_id = experiment_context[:assignment_id]

      # Phase 1: Decompose the feature into sub-tasks
      planning_result = run_planning(project_id, issue_id, coordination_policy:)

      tasks = planning_result[:tasks] || []
      created_issues = planning_result[:created_issues]
      planning_context = planning_result[:context] || {}
      prompt_source = planning_result[:prompt_source]

      scaling_experiment_context = safely_resolve_scaling_experiment(
        project_id: project_id,
        issue_id: issue_id,
        workflow_id: workflow_id,
        task_count: tasks.size
      )
      scaling_execution_plan = scaling_experiment_context[:execution_plan]
      scaling_assignment_id = scaling_experiment_context[:assignment_id]
      coordination_policy = apply_scaling_execution_plan(coordination_policy, scaling_execution_plan)

      # Update labels/state immediately after planning completes (mirrors PlanningWorkflow step 4)
      decision_step = "update_planning_labels"
      @decision_step = decision_step
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
        input_context: planning_context,
        plan_data: {
          tasks: tasks,
          created_issues: created_issues
        },
        metadata: {
          prompt_source: prompt_source,
          failed_step: nil,
          activity_boundaries: %w[
            Activities::FetchPlanningContextActivity
            Activities::DecomposeFeatureActivity
            Activities::CreateSubIssuesActivity
            Activities::UpdatePlanningLabelsActivity
          ]
        }
      )

      # If planning produced 0-1 tasks, no parallel execution needed
      decision_phase = "parallelization"
      unless tasks.size > 1
        safe_log_decomposition_decision(
          project_id: project_id,
          issue_id: issue_id,
          decision_key: "#{workflow_id}:parallelization_outcome:final",
          workflow_name: self.class.name,
          workflow_id: workflow_id,
          decision_type: "parallelization_outcome",
          outcome: parallelization_outcome_for(tasks),
          input_context: planning_context,
          plan_data: {
            tasks: tasks,
            created_issues: created_issues
          },
          metadata: {
            prompt_source: prompt_source,
            failed_step: nil,
            activity_boundaries: [ "Workflows::ParallelAgentExecutionWorkflow" ]
          }
        )

        Temporalio::Workflow.logger.info(
          message: "feature_orchestration.single_task_skip",
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size
        )
        result = {
          success: true,
          project_id: project_id,
          issue_id: issue_id,
          task_count: tasks.size,
          parallel_execution: false
        }
        scaling_observation = safe_record_scaling_observation(
          project_id: project_id,
          issue_id: issue_id,
          workflow_id: workflow_id,
          workflow_name: self.class.name,
          tasks: tasks,
          started_at: workflow_started_at,
          metadata: {
            prompt_source: prompt_source,
            created_issues: created_issues,
            scaling_experiment: scaling_metadata(scaling_execution_plan, scaling_assignment_id)
          }
        )
        safely_record_scaling_experiment_result(
          assignment_id: scaling_assignment_id,
          scaling_observation_id: scaling_observation&.dig(:scaling_observation_id)
        )
        safely_record_coordination_outcome(
          assignment_id: coordination_assignment_id,
          task_count: tasks.size,
          parallel_execution: false,
          result: result
        )
        return result
      end

      # Phase 2: Launch parallel execution on all sub-tasks
      decision_step = "build_sub_tasks"
      @decision_step = decision_step
      sub_tasks = build_sub_tasks(tasks, created_issues)

      safe_log_decomposition_decision(
        project_id: project_id,
        issue_id: issue_id,
        decision_key: "#{workflow_id}:parallelization_outcome:final",
        workflow_name: self.class.name,
        workflow_id: workflow_id,
        decision_type: "parallelization_outcome",
        outcome: "parallel_execution_planned",
        input_context: planning_context,
        plan_data: {
          tasks: tasks,
          created_issues: created_issues,
          sub_tasks: sub_tasks
        },
        metadata: {
          prompt_source: prompt_source,
          failed_step: nil,
          activity_boundaries: [ "Workflows::ParallelAgentExecutionWorkflow" ]
        }
      )

      decision_step = "run_parallel_execution"
      @decision_step = decision_step
      parallel_result = run_parallel_execution(
        project_id: project_id,
        issue_id: issue_id,
        sub_tasks: sub_tasks,
        timeout_seconds: timeout_seconds,
        aggregate_pr: input[:aggregate_pr],
        coordination_policy:
      )

      safely_record_coordination_outcome(
        assignment_id: coordination_assignment_id,
        task_count: tasks.size,
        parallel_execution: true,
        result: parallel_result
      )

      Temporalio::Workflow.logger.info(
        message: "feature_orchestration.completed",
        project_id: project_id,
        issue_id: issue_id,
        completed: parallel_result[:completed],
        failed: parallel_result[:failed]
      )

      scaling_observation = safe_record_scaling_observation(
        project_id: project_id,
        issue_id: issue_id,
        workflow_id: workflow_id,
        workflow_name: self.class.name,
        tasks: tasks,
        parallel_result: parallel_result,
        started_at: workflow_started_at,
        metadata: {
          prompt_source: prompt_source,
          created_issues: created_issues,
          scaling_experiment: scaling_metadata(scaling_execution_plan, scaling_assignment_id)
        }
      )
      safely_record_scaling_experiment_result(
        assignment_id: scaling_assignment_id,
        scaling_observation_id: scaling_observation&.dig(:scaling_observation_id)
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
      failed_step = @decision_step || decision_step

      safe_log_decomposition_decision(
        project_id: project_id,
        issue_id: issue_id,
        decision_key: "#{workflow_id}:#{decision_phase}_outcome:failure",
        workflow_name: self.class.name,
        workflow_id: workflow_id,
        decision_type: decision_phase == "parallelization" ? "parallelization_outcome" : "planning_outcome",
        outcome: decision_phase == "parallelization" ? parallelization_failure_outcome_for(failed_step) : planning_failure_outcome_for(failed_step),
        input_context: planning_context,
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
          failed_step: failed_step
        }
      )

      scaling_observation = safe_record_scaling_observation(
        project_id: project_id,
        issue_id: issue_id,
        workflow_id: workflow_id,
        workflow_name: self.class.name,
        tasks: tasks,
        parallel_result: parallel_result,
        started_at: workflow_started_at,
        error_details: {
          error_class: e.class.to_s,
          error_message: e.message,
          failed_step: failed_step
        },
        metadata: {
          prompt_source: prompt_source,
          created_issues: created_issues,
          scaling_experiment: scaling_metadata(scaling_execution_plan, scaling_assignment_id)
        }
      )
      safely_record_scaling_experiment_result(
        assignment_id: scaling_assignment_id,
        scaling_observation_id: scaling_observation&.dig(:scaling_observation_id)
      )

      Temporalio::Workflow.logger.error(
        message: "feature_orchestration.failed",
        project_id: project_id,
        issue_id: issue_id,
        error_class: e.class.to_s,
        error: e.message
      )
      safely_record_coordination_outcome(
        assignment_id: coordination_assignment_id,
        task_count: tasks.size,
        parallel_execution: tasks.size > 1,
        result: {
          success: false,
          completed: 0,
          failed: tasks.size,
          results: [],
          conflicts: { has_conflicts: false, requires_manual_review: false },
          error: e.message
        }
      )
      raise
    end

    private

    # Inline planning steps (mirrors PlanningWorkflow) rather than invoking it as a child
    # workflow because orchestration needs direct access to the decomposed tasks and created
    # issues to build sub_tasks for parallel execution. A child workflow would only return a
    # summary, requiring re-fetching. Shared activities keep the actual logic deduplicated.
    def run_planning(project_id, issue_id, coordination_policy:)
      # Step 1: Fetch knowledge base context
      @decision_step = "fetch_planning_context"
      context_result = run_activity(
        Activities::FetchPlanningContextActivity,
        { project_id: project_id, issue_id: issue_id },
        timeout: 60
      )

      # Step 2: Decompose into sub-tasks
      @decision_step = "decompose_feature"
      decompose_result = run_activity(
        Activities::DecomposeFeatureActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          knowledge_context: context_result[:context],
          coordination_policy: coordination_policy
        },
        timeout: 120
      )

      tasks = decompose_result[:tasks]
      prompt_source = decompose_result[:prompt_source]
      created_issues = []

      # Step 3: Create sub-issues if multiple tasks
      if tasks.present? && tasks.size > 1
        @decision_step = "create_sub_issues"
        create_result = run_activity(
          Activities::CreateSubIssuesActivity,
          {
            project_id: project_id,
            parent_issue_id: issue_id,
            creation_mode: Activities::CreateSubIssuesActivity::ORCHESTRATION_MODE,
            sub_tasks: tasks.map do |task|
              {
                title: task[:title],
                body: task[:description],
                dependencies: Array(task[:dependencies])
              }
            end
          },
          timeout: 120,
          retry_policy: Temporalio::RetryPolicy.new(max_attempts: 1)
        )

        created_issues = create_result[:created_issues]
      end

      { tasks: tasks, created_issues: created_issues, context: context_result[:context], prompt_source: prompt_source }
    end

    def build_sub_tasks(tasks, created_issues)
      created_issues_by_index = created_issues.each_with_index.each_with_object({}) do |(issue, fallback_index), memo|
        memo[issue.fetch(:index, fallback_index)] = issue
      end

      tasks.each_with_index.map do |task, index|
        sub_task = {
          custom_prompt: task[:description],
          task_index: task.fetch(:index, index),
          dependencies: Array(task[:dependencies]),
          parallel_group: task[:parallel_group]
        }

        # Link to created issue — require a valid issue_id since downstream
        # workflows (AgentExecutionWorkflow) depend on it for state tracking.
        if created_issues_by_index[index]
          issue_id = created_issues_by_index[index][:issue_id]
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

    def run_parallel_execution(project_id:, issue_id:, sub_tasks:, timeout_seconds:, aggregate_pr:, coordination_policy:)
      parent_wf_id = Temporalio::Workflow.info.workflow_id

      child_input = {
        project_id: project_id,
        sub_tasks: sub_tasks,
        parent_workflow_id: parent_wf_id,
        parent_issue_id: issue_id,
        timeout_seconds: timeout_seconds
      }
      child_input[:aggregate_pr] = aggregate_pr unless aggregate_pr.nil?
      child_input[:coordination_policy] = coordination_policy if coordination_policy.present?

      workflow_id = "parallel-#{parent_wf_id}-#{Temporalio::Workflow.now.to_i}"

      Temporalio::Workflow.execute_child_workflow(
        Workflows::ParallelAgentExecutionWorkflow,
        child_input,
        id: workflow_id,
        execution_timeout: timeout_seconds + 300,
        task_queue: Paid::AGENT_TASK_QUEUE
      )
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

    def parallelization_outcome_for(tasks)
      return "parallel_execution_skipped_empty_plan" if tasks.empty?
      return "parallel_execution_skipped_single_task" if tasks.one?

      "parallel_execution_planned"
    end

    def parallelization_failure_outcome_for(step)
      case step
      when "build_sub_tasks" then "parallelization_planning_failed"
      else "parallelization_failed"
      end
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
        message: "feature_orchestration.decomposition_decision_log_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        error_class: log_error.class.to_s,
        error: log_error.message
      )
    end

    def safe_record_scaling_observation(payload)
      run_activity(
        Activities::RecordScalingObservationActivity,
        payload,
        timeout: 30,
        retry_policy: NO_RETRY
      )
    rescue => record_error
      Temporalio::Workflow.logger.warn(
        message: "feature_orchestration.scaling_observation_record_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        error_class: record_error.class.to_s,
        error: record_error.message
      )
    end

    def safely_resolve_scaling_experiment(project_id:, issue_id:, workflow_id:, task_count:)
      run_activity(
        Activities::ResolveScalingExperimentActivity,
        { project_id:, issue_id:, workflow_id:, task_count: },
        timeout: 30,
        retry_policy: NO_RETRY
      )
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "feature_orchestration.scaling_experiment_resolution_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        error_class: e.class.to_s,
        error: e.message
      )
      { assignment_id: nil, execution_plan: nil }
    end

    def safely_resolve_coordination_experiment(project_id:, issue_id:, workflow_id:)
      run_activity(
        Activities::ResolveCoordinationExperimentActivity,
        { project_id:, issue_id:, workflow_id: },
        timeout: 30,
        retry_policy: NO_RETRY
      )
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "feature_orchestration.coordination_experiment_resolution_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        error_class: e.class.to_s,
        error: e.message
      )
      { assignment_id: nil, coordination_policy: nil }
    end

    def safely_record_coordination_outcome(assignment_id:, task_count:, parallel_execution:, result:)
      return unless assignment_id

      run_activity(
        Activities::RecordCoordinationExperimentOutcomeActivity,
        {
          assignment_id: assignment_id,
          task_count: task_count,
          parallel_execution: parallel_execution,
          result: result
        },
        timeout: 30,
        retry_policy: NO_RETRY
      )
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "feature_orchestration.coordination_experiment_record_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        assignment_id: assignment_id,
        error_class: e.class.to_s,
        error: e.message
      )
    end

    def safely_record_scaling_experiment_result(assignment_id:, scaling_observation_id:)
      return unless assignment_id && scaling_observation_id

      run_activity(
        Activities::RecordScalingExperimentResultActivity,
        {
          assignment_id: assignment_id,
          scaling_observation_id: scaling_observation_id
        },
        timeout: 30,
        retry_policy: NO_RETRY
      )
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "feature_orchestration.scaling_experiment_record_failed",
        workflow_id: Temporalio::Workflow.info.workflow_id,
        assignment_id: assignment_id,
        scaling_observation_id: scaling_observation_id,
        error_class: e.class.to_s,
        error: e.message
      )
    end

    def apply_scaling_execution_plan(policy, execution_plan)
      return policy unless execution_plan.present?

      requested_agent_count = execution_plan[:max_batch_size] || execution_plan["max_batch_size"]
      return policy unless requested_agent_count

      normalized_policy = (policy || {}).deep_dup
      normalized_policy["parallel_execution"] ||= {}
      normalized_policy["parallel_execution"]["max_batch_size"] = requested_agent_count
      normalized_policy
    end

    def scaling_metadata(execution_plan, assignment_id)
      return unless assignment_id && execution_plan.present?

      {
        assignment_id: assignment_id,
        requested_agent_count: execution_plan[:requested_agent_count] || execution_plan["requested_agent_count"],
        max_batch_size: execution_plan[:max_batch_size] || execution_plan["max_batch_size"]
      }.compact
    end
  end
end
