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
  #   2. Launches child AgentExecutionWorkflow instances respecting concurrency limits
  #   3. Tracks progress of all child workflows
  #   4. Propagates cancellation to all children on timeout or parent cancellation
  #   5. Returns aggregate results
  class ParallelAgentExecutionWorkflow < BaseWorkflow
    # Default overall timeout for parallel execution (2 hours)
    DEFAULT_TIMEOUT_SECONDS = 7200
    # Maximum sub-tasks allowed per parallel execution
    MAX_SUB_TASKS = 20
    # Interval for polling child workflow progress
    PROGRESS_POLL_INTERVAL = 30

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
        Temporalio::Workflow.logger.warn(
          message: "parallel_execution.no_capacity",
          project_id: project_id
        )
        return {
          success: false,
          error: "no_capacity",
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

      # Step 3: Return aggregate results
      completed = results.count { |r| r[:success] }
      failed = results.count { |r| r[:success] == false }

      Temporalio::Workflow.logger.info(
        message: "parallel_execution.completed",
        project_id: project_id,
        total: sub_tasks.size,
        completed: completed,
        failed: failed
      )

      {
        success: failed == 0,
        total: sub_tasks.size,
        completed: completed,
        failed: failed,
        results: results
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
