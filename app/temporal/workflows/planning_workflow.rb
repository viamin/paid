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
  # 4. Wait for plan review approval (signal gate: approve_plan / reject_plan / revise_plan)
  # 5. Create sub-issues in GitHub
  # 6. Update labels on the parent issue
  class PlanningWorkflow < BaseWorkflow
    NO_RETRY = Temporalio::RetryPolicy.new(max_attempts: 1)
    DEFAULT_PLAN_REVIEW_TIMEOUT_HOURS = 24

    workflow_signal
    def approve_plan
      @plan_review_decision = :approved
      @plan_review_cancel_proc&.call
    end

    workflow_signal
    def reject_plan
      @plan_review_decision = :rejected
      @plan_review_cancel_proc&.call
    end

    workflow_signal
    def revise_plan(revised_tasks)
      @plan_review_decision = :revised
      @revised_tasks = deep_symbolize(revised_tasks)
      @plan_review_cancel_proc&.call
    end

    class << self
      def outcome_mappings
        {
          success: planning_success_outcomes + %w[plan_review_rejected],
          failure: {
            "decompose_feature" => planning_failure_outcome_for("decompose_feature"),
            "create_sub_issues" => planning_failure_outcome_for("create_sub_issues"),
            "update_planning_labels" => planning_failure_outcome_for("update_planning_labels")
          }
        }
      end

      def planning_outcome_for(tasks, review_outcome: nil)
        return "plan_review_rejected" if review_outcome == :rejected
        return "empty_plan" if tasks.empty?
        return "single_task_plan" if tasks.one?

        "sub_issues_created"
      end

      def planning_success_outcomes
        %w[empty_plan single_task_plan sub_issues_created plan_review_approved plan_review_timed_out]
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
      timeout_hours = input[:plan_review_timeout_hours] || DEFAULT_PLAN_REVIEW_TIMEOUT_HOURS

      Temporalio::Workflow.logger.info(
        "PlanningWorkflow started for project=#{project_id} issue=#{issue_id}"
      )

      context_result = {}
      tasks = []
      reviewed_tasks = []
      created_issues = []
      prompt_source = nil
      policy_metadata = {}
      decision_step = "fetch_planning_context"
      review_outcome = nil

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

      reviewed_tasks = tasks

      # Review signal gate: wait for approval before creating sub-issues
      if plan_review_required?(tasks)
        review_outcome = wait_for_plan_review(
          project_id: project_id,
          issue_id: issue_id,
          workflow_id: workflow_id,
          tasks: tasks,
          context: context_result[:context],
          prompt_source: prompt_source,
          policy_metadata: policy_metadata,
          timeout_hours: timeout_hours
        )

        reviewed_tasks = resolve_reviewed_tasks(tasks, review_outcome)
      end

      # Step 3: Create sub-issues from the plan
      if reviewed_tasks.present? && reviewed_tasks.size > 1 && review_outcome != :rejected
        sub_tasks = build_sub_tasks(reviewed_tasks)

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
          task_count: reviewed_tasks.size
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
        outcome: self.class.planning_outcome_for(reviewed_tasks, review_outcome: review_outcome),
        input_context: context_result[:context],
        plan_data: {
          tasks: reviewed_tasks,
          created_issues: created_issues
        },
        metadata: {
          prompt_source: prompt_source,
          **policy_metadata,
          failed_step: nil,
          plan_review_outcome: review_outcome&.to_s,
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
        task_count: reviewed_tasks.size,
        created_issues: created_issues
      }

    rescue => e
      raise_if_canceled!(e)
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
          tasks: reviewed_tasks.presence || tasks,
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
        },
        detached: true
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

    def plan_review_required?(tasks)
      tasks.present? && tasks.size > 1
    end

    def resolve_reviewed_tasks(tasks, review_outcome)
      review_outcome == :revised ? Array(@revised_tasks) : tasks
    end

    def build_sub_tasks(tasks)
      tasks.map { |t| { title: t[:title], body: t[:description] } }
    end

    def wait_for_plan_review(project_id:, issue_id:, workflow_id:, tasks:, context:,
                             prompt_source:, policy_metadata:, timeout_hours:)
      @plan_review_decision = nil
      @revised_tasks = nil

      safe_log_decomposition_decision(
        project_id: project_id,
        issue_id: issue_id,
        decision_key: "#{workflow_id}:plan_review:pending",
        workflow_name: self.class.name,
        workflow_id: workflow_id,
        decision_type: "planning_outcome",
        outcome: "plan_pending_review",
        input_context: context,
        plan_data: { tasks: tasks },
        metadata: {
          prompt_source: prompt_source,
          **policy_metadata
        }
      )

      cancellation, @plan_review_cancel_proc = Temporalio::Cancellation.new

      begin
        timeout_seconds = timeout_hours.to_i * 3600
        Temporalio::Workflow.sleep(timeout_seconds, cancellation: cancellation) unless @plan_review_decision
      rescue Temporalio::Error::CanceledError
        # Signal arrived — decision is in @plan_review_decision
      ensure
        @plan_review_cancel_proc = nil
      end

      decision = @plan_review_decision || :timed_out

      safe_log_decomposition_decision(
        project_id: project_id,
        issue_id: issue_id,
        decision_key: "#{workflow_id}:plan_review:#{decision}",
        workflow_name: self.class.name,
        workflow_id: workflow_id,
        decision_type: "planning_outcome",
        outcome: "plan_review_#{decision}",
        input_context: context,
        plan_data: { tasks: decision == :revised ? @revised_tasks : tasks },
        metadata: {
          prompt_source: prompt_source,
          **policy_metadata
        }
      )

      decision
    end

    def safe_log_decomposition_decision(detached: false, **payload)
      if detached
        run_cleanup_activity(
          Activities::LogDecompositionDecisionActivity,
          payload,
          timeout: 30,
          retry_policy: NO_RETRY
        )
      else
        run_activity(
          Activities::LogDecompositionDecisionActivity,
          payload,
          timeout: 30,
          retry_policy: NO_RETRY
        )
      end
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
