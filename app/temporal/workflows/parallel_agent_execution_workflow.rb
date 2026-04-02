# frozen_string_literal: true

module Workflows
  # Orchestrates parallel execution of multiple AgentExecutionWorkflow instances
  # for independent sub-tasks from a decomposed feature.
  #
  # Input:
  #   project_id: ID of the project
  #   sub_tasks: Array of sub-task hashes, each containing:
  #     - issue_id: ID of the sub-task issue
  #     - agent_type: (optional) Agent type to use
  #     - custom_prompt: (optional) Custom prompt for this sub-task
  #     - goal: (optional) Goal type (defaults to "create_pr")
  #   parent_workflow_id: (optional) Identifier for this parallel execution group
  #   timeout_seconds: (optional) Overall timeout for all parallel tasks
  #
  # The workflow:
  #   1. Checks project-level capacity for parallel runs
  #   2. Launches child AgentExecutionWorkflow instances in batches respecting concurrency limits
  #   3. Re-checks capacity between batches and enforces an overall deadline
  #   4. Returns aggregate results
  class ParallelAgentExecutionWorkflow < BaseWorkflow
    # Default overall timeout for parallel execution (2 hours)
    DEFAULT_TIMEOUT_SECONDS = 7200
    # Maximum sub-tasks allowed per parallel execution
    MAX_SUB_TASKS = 20

    def execute(input)
      project_id = input[:project_id]
      sub_tasks = input.fetch(:sub_tasks, [])
      parent_wf_id = input[:parent_workflow_id] || Temporalio::Workflow.info.workflow_id
      timeout_seconds = input.fetch(:timeout_seconds, DEFAULT_TIMEOUT_SECONDS)

      Temporalio::Workflow.logger.info(
        message: "parallel_execution.started",
        project_id: project_id,
        sub_task_count: sub_tasks.size,
        parent_workflow_id: parent_wf_id
      )

      validate_input!(project_id, sub_tasks)

      # Step 1: Check project-level capacity
      capacity = run_activity(
        Activities::CheckProjectRunCapacityActivity,
        { project_id: project_id },
        timeout: 30
      )

      unless capacity[:has_capacity]
        error_code = capacity[:error] || "no_capacity"
        Temporalio::Workflow.logger.warn(
          message: "parallel_execution.no_capacity",
          project_id: project_id,
          error: error_code
        )
        return {
          success: false,
          error: error_code,
          project_active_count: capacity[:project_active_count],
          max_parallel_per_project: capacity[:max_parallel_per_project]
        }
      end

      # Step 2: Launch child workflows with concurrency control
      max_concurrent = capacity[:available_slots]
      results = launch_and_monitor_children(
        project_id: project_id,
        sub_tasks: sub_tasks,
        max_concurrent: max_concurrent,
        parent_wf_id: parent_wf_id,
        timeout_seconds: timeout_seconds
      )

      # Step 3: Detect conflicts between successful runs
      completed = results.count { |r| r[:success] }
      failed = results.count { |r| r[:success] == false }

      conflict_result = detect_and_resolve_conflicts(
        results: results,
        project_id: project_id
      )

      Temporalio::Workflow.logger.info(
        message: "parallel_execution.completed",
        project_id: project_id,
        total: sub_tasks.size,
        completed: completed,
        failed: failed,
        has_conflicts: conflict_result[:has_conflicts]
      )

      {
        success: failed == 0,
        total: sub_tasks.size,
        completed: completed,
        failed: failed,
        results: results,
        conflicts: conflict_result
      }
    end

    private

    def validate_input!(project_id, sub_tasks)
      unless project_id
        raise Temporalio::Error::ApplicationError.new(
          "project_id is required",
          type: "InvalidInput",
          non_retryable: true
        )
      end

      if sub_tasks.empty?
        raise Temporalio::Error::ApplicationError.new(
          "sub_tasks must not be empty",
          type: "InvalidInput",
          non_retryable: true
        )
      end

      if sub_tasks.size > MAX_SUB_TASKS
        raise Temporalio::Error::ApplicationError.new(
          "sub_tasks exceeds maximum of #{MAX_SUB_TASKS}",
          type: "InvalidInput",
          non_retryable: true
        )
      end

      sub_tasks.each_with_index do |sub_task, index|
        unless sub_task.is_a?(Hash)
          raise Temporalio::Error::ApplicationError.new(
            "sub_tasks[#{index}] must be a Hash",
            type: "InvalidInput",
            non_retryable: true
          )
        end

        if sub_task[:issue_id].nil? && sub_task[:custom_prompt].nil?
          raise Temporalio::Error::ApplicationError.new(
            "sub_tasks[#{index}] must include at least one of :issue_id or :custom_prompt",
            type: "InvalidInput",
            non_retryable: true
          )
        end
      end
    end

    # Launches child workflows in batches respecting concurrency limits,
    # then waits for all to complete. Recomputes batch size from the latest
    # capacity check before each batch, and enforces an overall deadline
    # derived from timeout_seconds.
    def launch_and_monitor_children(project_id:, sub_tasks:, max_concurrent:, parent_wf_id:, timeout_seconds:)
      deadline = Temporalio::Workflow.now + timeout_seconds
      remaining_tasks = sub_tasks.dup
      all_results = []
      batch_index = 0
      current_slots = max_concurrent

      while remaining_tasks.any?
        remaining_seconds = deadline - Temporalio::Workflow.now
        if remaining_seconds <= 0
          remaining_tasks.each do |task|
            all_results << {
              issue_id: task[:issue_id],
              success: false,
              error: "deadline_exceeded",
              queued: true
            }
          end
          break
        end

        # Re-check capacity before each batch (except the first, already checked)
        if batch_index > 0
          capacity = run_activity(
            Activities::CheckProjectRunCapacityActivity,
            { project_id: project_id },
            timeout: 30
          )

          unless capacity[:has_capacity]
            remaining_tasks.each do |task|
              all_results << {
                issue_id: task[:issue_id],
                success: false,
                error: "no_capacity",
                queued: true
              }
            end
            break
          end

          current_slots = capacity[:available_slots]
        end

        batch_size = [ current_slots, remaining_tasks.size ].min
        batch = remaining_tasks.shift(batch_size)

        batch_results = execute_batch(
          project_id: project_id,
          batch: batch,
          batch_index: batch_index,
          parent_wf_id: parent_wf_id,
          deadline: deadline
        )

        all_results.concat(batch_results)
        batch_index += 1
      end

      all_results
    end

    # Detects and attempts to resolve conflicts between successful parallel runs.
    # Only checks runs that completed successfully and produced agent_run_ids.
    # Returns a summary of conflict detection and resolution outcomes.
    def detect_and_resolve_conflicts(results:, project_id:)
      successful_run_ids = results
        .select { |r| r[:success] && r[:agent_run_id] }
        .map { |r| r[:agent_run_id] }

      return no_conflicts_result(project_id: project_id) if successful_run_ids.size < 2

      detection = run_activity(
        Activities::DetectConflictsActivity,
        { agent_run_ids: successful_run_ids, project_id: project_id },
        timeout: 120
      )

      unless detection[:has_conflicts]
        return detection.merge(resolution: nil)
      end

      # If detection itself failed (all diff sources returned empty),
      # require manual review without attempting resolution.
      if detection[:detection_failed]
        return detection.merge(resolution: nil)
      end

      resolution = run_activity(
        Activities::ResolveConflictsActivity,
        { detection_result: detection, project_id: project_id, strategy: "auto_rebase" },
        timeout: 300
      )

      detection.merge(
        resolution: resolution,
        requires_manual_review: resolution[:requires_manual_review] || detection[:requires_manual_review]
      )
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "parallel_execution.conflict_detection_failed",
        project_id: project_id,
        error_class: e.class.name,
        error: e.message
      )
      {
        has_conflicts: true,
        conflicting_pairs: [],
        files_by_run: {},
        total_runs_checked: 0,
        project_id: project_id,
        detection_failed: true,
        requires_manual_review: true,
        resolution: nil,
        error: e.message
      }
    end

    def no_conflicts_result(project_id: nil)
      {
        has_conflicts: false,
        conflicting_pairs: [],
        files_by_run: {},
        total_runs_checked: 0,
        project_id: project_id,
        detection_failed: false,
        requires_manual_review: false,
        resolution: nil
      }
    end

    # Launches a batch of child workflows in parallel and waits for all to complete.
    # Each child receives the remaining time until the workflow-level deadline,
    # ensuring the overall timeout_seconds cap is respected across all batches.
    def execute_batch(project_id:, batch:, batch_index:, parent_wf_id:, deadline:)
      timestamp = Temporalio::Workflow.now.to_i
      child_timeout = [ (deadline - Temporalio::Workflow.now).to_i, 1 ].max

      # Start all child workflows in this batch
      child_futures = batch.map.with_index do |task, task_index|
        issue_id = task[:issue_id]
        workflow_id = "parallel-#{parent_wf_id}-#{batch_index}-#{task_index}-#{issue_id}-#{timestamp}"
        agent_type = task.fetch(:agent_type, "claude_code")
        goal = task.fetch(:goal, "create_pr")

        child_input = {
          project_id: project_id,
          issue_id: issue_id,
          agent_type: agent_type,
          goal: goal,
          parent_workflow_id: parent_wf_id
        }
        child_input[:custom_prompt] = task[:custom_prompt] if task[:custom_prompt]

        Temporalio::Workflow.logger.info(
          message: "parallel_execution.launching_child",
          project_id: project_id,
          issue_id: issue_id,
          workflow_id: workflow_id,
          batch_index: batch_index
        )

        future = Temporalio::Workflow::Future.new do
          Temporalio::Workflow.execute_child_workflow(
            Workflows::AgentExecutionWorkflow,
            child_input,
            id: workflow_id,
            execution_timeout: child_timeout,
            cancellation_type: Temporalio::Workflow::ChildWorkflowCancellationType::WAIT_CANCELLATION_COMPLETED
          )
        end

        { future: future, issue_id: issue_id, workflow_id: workflow_id }
      end

      # Wait for all futures to complete (success or failure)
      Temporalio::Workflow::Future.try_all_of(
        *child_futures.map { |cf| cf[:future] }
      ).wait

      # Collect results
      child_futures.map do |child|
        if child[:future].failure?
          error = child[:future].failure
          Temporalio::Workflow.logger.warn(
            message: "parallel_execution.child_failed",
            issue_id: child[:issue_id],
            workflow_id: child[:workflow_id],
            error: error.message
          )
          {
            issue_id: child[:issue_id],
            workflow_id: child[:workflow_id],
            success: false,
            error: error.message
          }
        else
          result = child[:future].result || {}
          {
            issue_id: child[:issue_id],
            workflow_id: child[:workflow_id],
            success: result[:success] || false,
            agent_run_id: result[:agent_run_id]
          }
        end
      end
    end
  end
end
