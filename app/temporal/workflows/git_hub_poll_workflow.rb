# frozen_string_literal: true

module Workflows
  # Continuously polls GitHub for labeled issues on a project and triggers
  # agent execution workflows when actionable labels are detected.
  #
  # Runs as a long-lived workflow, sleeping between poll cycles. Can be
  # cancelled via ProjectWorkflowManager.stop_polling.
  #
  # Uses continue-as-new to prevent workflow history from exceeding
  # Temporal's event limit. The server signals when history is getting
  # large via continue_as_new_suggested; a hard cap provides a safety net.
  class GitHubPollWorkflow < BaseWorkflow
    MAX_ITERATIONS = 100
    JITTER_FRACTION = 0.15

    workflow_signal
    def request_sync
      @sync_requested = true
      @sleep_cancel_proc&.call
    end

    def execute(input)
      project_id = input[:project_id]
      iterations = 0

      loop do
        @sync_requested = false

        result = run_activity(Activities::FetchIssuesActivity,
          { project_id: project_id }, timeout: 60)

        break if result[:project_missing]

        record_poll_heartbeat(project_id)

        queue_enhance_issue_rechecks(project_id, result[:enhance_issue_rechecks])

        evaluate_issues_batch(project_id, result[:issues])

        record_poll_heartbeat(project_id)

        pr_scan_result = maybe_run_non_critical_activities(project_id)

        run_notification_rules(project_id,
          issue_ids: result[:issues].map { |issue| issue[:id] },
          pr_scan_result: pr_scan_result)

        record_poll_heartbeat(project_id)

        poll_config = run_activity(Activities::GetPollIntervalActivity,
          { project_id: project_id }, timeout: 10)

        break if poll_config[:project_missing]

        iterations += 1
        if iterations >= MAX_ITERATIONS || Temporalio::Workflow.continue_as_new_suggested
          raise Temporalio::Workflow::ContinueAsNewError.new({ project_id: project_id })
        end

        interval = poll_config[:poll_interval_seconds]
        jitter = with_jitter(interval)

        interruptible_sleep(jitter)
      end
    end

    def execute_automation_decision(project_id:, decision:)
      case decision.fetch(:type)
      when "noop"
        nil
      when "queue_create_pr_run"
        queue_create_pr_run(project_id, decision)
      when "queue_review_run"
        queue_review_run(project_id, decision)
      when "queue_analyze_issue_run"
        run_activity(Activities::QueueAgentRunActivity, {
          project_id: project_id,
          issue_id: decision[:issue_id],
          goal: "analyze_issue"
        }, timeout: 30)
      when "start_planning"
        if feature_flag_enabled?(:feature_orchestration, project_id:)
          start_feature_orchestration_workflow(project_id, decision[:issue_id])
        else
          start_planning_workflow(project_id, decision[:issue_id])
        end
      when "request_review"
        request_review(project_id, decision[:pr_number], decision[:reviewers],
          log_key: "pr_review.request_review_failed")
      when "dispatch_claude_review"
        run_activity(Activities::DispatchClaudeReviewActivity, {
          project_id: project_id,
          pr_number: decision[:pr_number]
        }, timeout: 60)
      when "mark_ready"
        handle_mark_ready(project_id, decision)
      when "escalate"
        handle_escalate_decision(project_id, decision)
      when "dismiss_escalation"
        handle_dismiss_escalation(project_id, decision)
      when "merge"
        handle_owner_approved(project_id,
          issue_id: decision[:issue_id], pr_number: decision[:pr_number])
      when "record_pr_followup"
        run_activity(Activities::RecordPrFollowupActivity, {
          project_id: project_id,
          issue_id: decision[:issue_id],
          labels_to_remove: decision[:labels_to_remove] || [],
          expected_followup_count: decision[:expected_followup_count]
        }, timeout: 30)
      when "record_review_goal_retry"
        run_activity(Activities::RecordReviewGoalRetryActivity, {
          issue_id: decision[:issue_id],
          expected_review_goal_retry_count: decision[:expected_review_goal_retry_count]
        }, timeout: 30)
      else
        Temporalio::Workflow.logger.warn(
          message: "workflow_decision_executor.unknown_decision_type",
          project_id: project_id,
          type: decision[:type]
        )
      end
    end

    private

    def evaluate_issues_batch(project_id, issues)
      return if issues.blank?

      issue_ids = issues.map { |issue_data| issue_data[:id] }
      batch_result = run_activity(Activities::EvaluateIssuesActivity,
        { project_id: project_id, issue_ids: issue_ids }, timeout: 120)

      (batch_result[:results] || []).each do |evaluation|
        handle_automation_result(evaluation, project_id)
      end
    end

    def record_poll_heartbeat(project_id)
      run_activity(Activities::RecordPollHeartbeatActivity,
        { project_id: project_id }, timeout: 10)
    end

    def queue_enhance_issue_rechecks(project_id, rechecks)
      Array(rechecks).each do |recheck|
        run_activity(Activities::QueueAgentRunActivity, {
          project_id: project_id,
          issue_id: recheck[:issue_id],
          goal: "enhance_issue"
        }, timeout: 30)
      end
    end

    def interruptible_sleep(duration)
      cancellation, @sleep_cancel_proc = Temporalio::Cancellation.new
      return if @sync_requested # Signal arrived before sleep — skip immediately

      Temporalio::Workflow.sleep(duration, cancellation: cancellation)
    rescue Temporalio::Error::CanceledError
      raise unless @sync_requested
      # Signal woke us — loop will restart immediately
    ensure
      @sleep_cancel_proc = nil
    end

    def with_jitter(base_seconds)
      jitter_range = base_seconds * JITTER_FRACTION
      base_seconds + Temporalio::Workflow.random.rand(-jitter_range..jitter_range)
    end

    # Checks rate limit budget and runs non-critical activities only when
    # sufficient budget remains. Issue detection (FetchIssues + DetectLabels)
    # is prioritized as core work; PR scanning, security alerts, and knowledge
    # staleness checks are skipped when budget is low.
    def maybe_run_non_critical_activities(project_id)
      rate_limit = run_activity(Activities::CheckRateLimitActivity,
        { project_id: project_id }, timeout: 10)

      if rate_limit[:rate_limit_low]
        Temporalio::Workflow.logger.info(
          message: "poll.non_critical_skipped_budget_low",
          project_id: project_id,
          rate_limit_remaining: rate_limit[:rate_limit_remaining]
        )
        return nil
      end

      scan_result = maybe_scan_paid_prs(project_id)
      maybe_scan_code_scanning_alerts(project_id)
      maybe_check_knowledge_staleness(project_id)
      maybe_evaluate_auto_release(project_id)
      maybe_evaluate_dependabot_auto_merge(project_id)
      scan_result
    end

    # Scan paid-generated PRs for follow-up work.
    def maybe_scan_paid_prs(project_id)
      scan_result = run_activity(Activities::ScanPaidPrsActivity,
        { project_id: project_id }, timeout: 120)

      handle_pr_scan_results(scan_result, project_id)
      scan_result
    end

    # Scan for CodeQL code scanning alerts and create synthetic issues.
    # Code scanning issues are picked up naturally by AutoPick — no immediate
    # agent runs are triggered here.
    def maybe_scan_code_scanning_alerts(project_id)
      run_activity(Activities::ScanSecurityAlertsActivity,
        { project_id: project_id }, timeout: 120)
    rescue Temporalio::Error::ActivityError => e
      raise unless e.cause.is_a?(Temporalio::Error::ApplicationError) &&
        e.cause.type == "CodeScanningPermissionsError"

      Temporalio::Workflow.logger.warn(
        message: "poll.code_scanning_configuration_error",
        project_id: project_id,
        error: e.cause.message
      )
    end

    # Check if the project's knowledge base needs refreshing after HEAD advances.
    def maybe_check_knowledge_staleness(project_id)
      run_activity(Activities::CheckKnowledgeStalenessActivity,
        { project_id: project_id }, timeout: 30)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "knowledge.staleness_check_failed",
        project_id: project_id,
        error_class: e.class.name,
        error: e.message
      )
    end

    # Evaluate auto-release for the project's open release-please PRs.
    # Runs on every poll cycle so webhooks are not required for auto-release.
    def maybe_evaluate_auto_release(project_id)
      run_activity(Activities::EvaluateAutoReleaseActivity,
        { project_id: project_id }, timeout: 30)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "auto_release.poll_evaluation_failed",
        project_id: project_id,
        error_class: e.class.name,
        error: e.message
      )
    end

    # Evaluate dependabot auto-merge for the project's open Dependabot PRs.
    # Runs on every poll cycle so webhooks are not required for auto-merge.
    def maybe_evaluate_dependabot_auto_merge(project_id)
      run_activity(Activities::EvaluateDependabotAutoMergeActivity,
        { project_id: project_id }, timeout: 30)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "dependabot_auto_merge.poll_evaluation_failed",
        project_id: project_id,
        error_class: e.class.name,
        error: e.message
      )
    end

    def run_notification_rules(project_id, issue_ids:, pr_scan_result:)
      pr_scan_result = normalize_scan_result(pr_scan_result)

      run_activity(Activities::EvaluateNotificationRulesActivity, {
        project_id: project_id,
        issue_ids: issue_ids,
        pr_issue_ids: Array(pr_scan_result&.dig(:pr_issue_ids)),
        pending_review_states: Array(pr_scan_result&.dig(:pending_review_states)),
        pr_progress_states: Array(pr_scan_result&.dig(:pr_progress_states))
      }, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "notifications.rule_evaluation_failed",
        project_id: project_id,
        error_class: e.class.name,
        error: e.message
      )
    end

    def normalize_scan_result(pr_scan_result)
      return unless pr_scan_result.respond_to?(:with_indifferent_access)

      pr_scan_result.with_indifferent_access
    end

    def handle_automation_result(result, project_id)
      Automation::WorkflowDecisionExecutor.call(workflow: self, project_id:, result:)
    end

    def queue_create_pr_run(project_id, decision)
      return unless quality_gate_allows_run?(project_id, decision, goal: "create_pr")

      queue_input = {
        project_id: project_id,
        issue_id: decision[:issue_id],
        source_pull_request_number: decision[:source_pull_request_number],
        goal: "create_pr",
        count_toward_draft_review_round: decision.fetch(:count_toward_draft_review_round, false),
        expected_draft_review_count: decision[:expected_draft_review_count]
      }.compact
      queue_input[:focus] = decision[:focus] || "general" if decision[:source_pull_request_number].present?
      queue_input.delete(:count_toward_draft_review_round) unless queue_input[:count_toward_draft_review_round]

      run_activity(Activities::QueueAgentRunActivity, queue_input, timeout: 30)
    end

    def queue_review_run(project_id, decision)
      return unless quality_gate_allows_run?(project_id, decision, goal: "review")

      run_activity(Activities::QueueAgentRunActivity, {
        project_id: project_id,
        issue_id: decision[:issue_id],
        source_pull_request_number: decision[:source_pull_request_number],
        goal: "review",
        focus: decision[:focus] || "general"
      }, timeout: 30)
    end

    # Starts the full feature orchestration workflow (plan → parallel execute → aggregate).
    # Used when the feature_orchestration flag is enabled for the project.
    def start_feature_orchestration_workflow(project_id, issue_id)
      capacity = run_activity(Activities::CheckRunCapacityActivity, { project_id: project_id }, timeout: 10)

      unless capacity[:has_capacity]
        Temporalio::Workflow.logger.info(
          message: "feature_orchestration.deferred_due_to_capacity",
          project_id: project_id,
          issue_id: issue_id
        )
        return
      end

      workflow_id = "orchestrate-#{project_id}-#{issue_id}-#{Temporalio::Workflow.now.to_i}"

      Temporalio::Workflow.start_child_workflow(
        Workflows::FeatureOrchestrationWorkflow,
        { project_id: project_id, issue_id: issue_id },
        id: workflow_id,
        task_queue: Paid::AGENT_TASK_QUEUE,
        parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
      )
    end

    # Unlike agent workflows, planning workflows cannot be queued via QueueAgentRunActivity
    # because ProcessRunQueueJob always starts AgentExecutionWorkflow. Instead of blocking
    # the poll workflow while waiting for capacity, we perform a single capacity check and
    # defer planning to a future poll cycle if needed.
    def start_planning_workflow(project_id, issue_id)
      capacity = run_activity(Activities::CheckRunCapacityActivity, { project_id: project_id }, timeout: 10)

      unless capacity[:has_capacity]
        Temporalio::Workflow.logger.info(
          message: "planning.deferred_due_to_capacity",
          project_id: project_id,
          issue_id: issue_id
        )
        return
      end

      workflow_id = "plan-#{project_id}-#{issue_id}-#{Temporalio::Workflow.now.to_i}"
      child_input = { project_id: project_id, issue_id: issue_id }

      timeout_config = run_activity(Activities::FetchPlanReviewTimeoutActivity,
        { project_id: project_id }, timeout: 10)
      child_input[:plan_review_timeout_hours] = timeout_config[:plan_review_timeout_hours]

      Temporalio::Workflow.start_child_workflow(
        Workflows::PlanningWorkflow,
        child_input,
        id: workflow_id,
        task_queue: Paid::AGENT_TASK_QUEUE,
        parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
      )
    end

    def handle_pr_scan_results(scan_result, project_id)
      (scan_result[:automation_results] || []).each do |result|
        handle_automation_result(result, project_id)
      end
    end

    def handle_mark_ready(project_id, decision)
      result = run_activity(Activities::MarkPrReadyActivity,
        { project_id: project_id, pr_number: decision[:pr_number],
          issue_id: decision[:issue_id] }, timeout: 60)

      return unless result[:marked_ready]

      reviewer = decision[:owner_reviewer_login]
      return if reviewer.blank?

      request_review(project_id, decision[:pr_number], [ reviewer ],
        log_key: "pr_review.request_owner_review_failed")
    end

    def handle_escalate_decision(project_id, decision)
      activity_input = { issue_id: decision[:issue_id], reason: decision[:reason], reason_key: decision[:reason_key] }.compact

      run_activity(Activities::MarkEscalatedActivity, activity_input, timeout: 30)

      reviewer = decision[:owner_reviewer_login]
      return if reviewer.blank?

      request_review(project_id, decision[:pr_number], [ reviewer ],
        log_key: "pr_review.request_owner_review_failed")
    end

    def handle_dismiss_escalation(project_id, pr_data)
      result = run_activity(Activities::DismissEscalationActivity,
        { issue_id: pr_data[:issue_id], draft: pr_data[:draft] == true },
        timeout: 30)
      return unless result[:dismissed]

      resumed_pr_data = {
        issue_id: result[:issue_id],
        pr_number: result[:pr_number],
        phase: result[:phase],
        current_draft_review_count: result[:current_draft_review_count],
        current_followup_count: result[:current_followup_count],
        labels_to_remove: []
      }

      if result[:phase].in?(%w[draft restarted])
        start_draft_followup_workflow(project_id, resumed_pr_data)
      else
        start_pr_followup_workflow(project_id, resumed_pr_data)
      end
    end

    def request_review(project_id, pr_number, reviewers, log_key:)
      run_activity(Activities::RequestReviewActivity,
        { project_id: project_id, pr_number: pr_number,
          reviewers: reviewers }, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: log_key,
        project_id: project_id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def handle_owner_approved(project_id, pr_data)
      result = run_activity(Activities::MergePullRequestActivity,
        { project_id: project_id, pr_number: pr_data[:pr_number],
          issue_id: pr_data[:issue_id] }, timeout: 60)

      maybe_trigger_dev_update(project_id, pr_data, result)
    end

    def maybe_trigger_dev_update(project_id, pr_data, merge_result)
      return unless merge_result[:merged]

      run_activity(Activities::TriggerDevEnvironmentUpdateActivity,
        { project_id: project_id, pr_number: pr_data[:pr_number] }, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "dev_update.trigger_failed",
        project_id: project_id,
        pr_number: pr_data[:pr_number],
        error: e.message
      )
    end

    def start_draft_followup_workflow(project_id, pr_data)
      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]
      return unless quality_gate_allows_run?(project_id, pr_data, goal: "create_pr")

      draft_input = {
        project_id: project_id,
        issue_id: issue_id,
        source_pull_request_number: pr_number,
        focus: pr_data[:focus] || "general",
        count_toward_draft_review_round: true,
        expected_draft_review_count: pr_data[:current_draft_review_count],
        goal: "create_pr"
      }
      run_activity(Activities::QueueAgentRunActivity, draft_input, timeout: 30)
    end

    def start_pr_followup_workflow(project_id, pr_data)
      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]
      return unless quality_gate_allows_run?(project_id, pr_data, goal: "create_pr")

      followup_input = {
        project_id: project_id,
        issue_id: issue_id,
        labels_to_remove: pr_data[:labels_to_remove] || [],
        expected_followup_count: pr_data[:current_followup_count]
      }

      followup_queue_input = { project_id: project_id, issue_id: issue_id,
        source_pull_request_number: pr_number,
        focus: pr_data[:focus] || "general",
        goal: "create_pr" }
      run_activity(Activities::QueueAgentRunActivity, followup_queue_input, timeout: 30)
      run_activity(Activities::RecordPrFollowupActivity, followup_input, timeout: 30)
    end

    def quality_gate_allows_run?(project_id, data, goal:)
      result = run_activity(Activities::CheckQualityGateActivity,
        {
          project_id: project_id,
          issue_id: data[:issue_id],
          source_pull_request_number: data[:source_pull_request_number] || data[:pr_number],
          goal: goal,
          workflow_id: current_workflow_id(project_id),
          workflow_type: "GitHubPollWorkflow"
        }.compact,
        timeout: 30)
      return true if result.fetch(:allowed, true)

      Temporalio::Workflow.logger.info(
        message: "quality_gate.queue_skipped",
        project_id: project_id,
        issue_id: data[:issue_id],
        pr_number: data[:source_pull_request_number] || data[:pr_number],
        goal: goal,
        reason: result[:reason],
        breach_count: Array(result[:breaches]).size
      )
      false
    end

    def current_workflow_id(project_id)
      Temporalio::Workflow.info.workflow_id
    rescue StandardError
      "github-poll-#{project_id}"
    end
  end
end
