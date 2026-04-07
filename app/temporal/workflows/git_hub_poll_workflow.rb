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

        result[:issues].each do |issue_data|
          detection = run_activity(Activities::DetectLabelsActivity,
            { project_id: project_id, issue_id: issue_data[:id] }, timeout: 30)

          handle_detection(detection, project_id)
        end

        maybe_scan_paid_prs(project_id)
        maybe_scan_code_scanning_alerts(project_id)
        maybe_check_knowledge_staleness(project_id)

        poll_config = run_activity(Activities::GetPollIntervalActivity,
          { project_id: project_id }, timeout: 10)

        break if poll_config[:project_missing]

        iterations += 1
        if iterations >= MAX_ITERATIONS || Temporalio::Workflow.continue_as_new_suggested
          raise Temporalio::Workflow::ContinueAsNewError.new({ project_id: project_id })
        end

        interruptible_sleep(poll_config[:poll_interval_seconds])
      end
    end

    private

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

    # Scan paid-generated PRs for follow-up work.
    # TODO(#220): Remove patch guard after all pre-v220 workflows have continued-as-new
    def maybe_scan_paid_prs(project_id)
      return unless Temporalio::Workflow.patched("add-scan-paid-prs-v1")

      scan_result = run_activity(Activities::ScanPaidPrsActivity,
        { project_id: project_id }, timeout: 120)

      handle_pr_scan_results(scan_result, project_id)
    end

    # Scan for CodeQL code scanning alerts and create synthetic issues.
    # Code scanning issues are picked up naturally by AutoPick — no immediate
    # agent runs are triggered here.
    # TODO(#220): Remove patch guard after all pre-v220 workflows have continued-as-new
    def maybe_scan_code_scanning_alerts(project_id)
      return unless Temporalio::Workflow.patched("add-scan-security-alerts-v1")

      run_activity(Activities::ScanSecurityAlertsActivity,
        { project_id: project_id }, timeout: 120)
    end

    # Check if the project's knowledge base needs refreshing after HEAD advances.
    # TODO(#220): Remove patch guard after all pre-v220 workflows have continued-as-new
    def maybe_check_knowledge_staleness(project_id)
      return unless Temporalio::Workflow.patched("add-check-knowledge-staleness-v1")

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

    def handle_detection(detection, project_id)
      case detection[:action]
      when "execute_agent"
        start_agent_workflow(project_id, detection[:issue_id],
          source_pull_request_number: detection[:source_pull_request_number])
      when "start_planning"
        start_planning_workflow(project_id, detection[:issue_id])
      end
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

      Temporalio::Workflow.start_child_workflow(
        Workflows::PlanningWorkflow,
        { project_id: project_id, issue_id: issue_id },
        id: workflow_id,
        parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
      )
    end

    def start_agent_workflow(project_id, issue_id, source_pull_request_number: nil)
      queue_input = { project_id: project_id, issue_id: issue_id }
      queue_input[:source_pull_request_number] = source_pull_request_number if source_pull_request_number
      run_activity(Activities::QueueAgentRunActivity, queue_input, timeout: 30)
    end

    def handle_pr_scan_results(scan_result, project_id)
      return if scan_result[:prs_to_trigger].blank?

      scan_result[:prs_to_trigger].each do |pr_data|
        handle_pr_trigger(project_id, pr_data)
      end
    end

    def handle_pr_trigger(project_id, pr_data)
      trigger_types = (pr_data[:triggers] || []).map { |t| t[:type] }

      if trigger_types.include?("ready_for_owner")
        handle_ready_for_owner(project_id, pr_data)
      elsif trigger_types.include?("escalate_to_owner")
        handle_escalate_to_owner(project_id, pr_data)
      elsif trigger_types.include?("owner_approved")
        handle_owner_approved(project_id, pr_data)
      elsif trigger_types.include?("review_bot_review_pending")
        handle_review_method_pending(project_id, pr_data, trigger_types)
      elsif passive_review_gate_only?(trigger_types)
        nil
      elsif pr_data[:phase].in?(%w[draft restarted])
        start_draft_followup_workflow(project_id, pr_data)
      else
        start_pr_followup_workflow(project_id, pr_data)
      end
    end

    def handle_ready_for_owner(project_id, pr_data)
      result = run_activity(Activities::MarkPrReadyActivity,
        { project_id: project_id, pr_number: pr_data[:pr_number],
          issue_id: pr_data[:issue_id] }, timeout: 60)

      return unless result[:marked_ready]

      request_owner_review(project_id, pr_data)
    end

    def handle_escalate_to_owner(project_id, pr_data)
      # Transition to escalated phase so the scanner stops re-emitting this trigger
      run_activity(Activities::MarkEscalatedActivity,
        { issue_id: pr_data[:issue_id] },
        timeout: 30)

      request_owner_review(project_id, pr_data)
    end

    def request_owner_review(project_id, pr_data)
      reviewer = pr_data[:owner_reviewer_login]
      return if reviewer.blank?

      request_review(project_id, pr_data[:pr_number], [ reviewer ],
        log_key: "pr_review.request_owner_review_failed")
    end

    def handle_review_method_pending(project_id, pr_data, trigger_types)
      # If there are other triggers besides review_bot_review_pending, a followup
      # agent will run and push changes. Defer automated review requests to the
      # AgentExecutionWorkflow so reviewers inspect the fixed code, not the
      # pre-fix state. When review_bot_review_pending is the only trigger, request
      # immediately since no followup will run.
      other_triggers = trigger_types - [ "review_bot_review_pending", Activities::ScanPaidPrsActivity::PASSIVE_REVIEW_GATE_TRIGGER ]

      if other_triggers.empty?
        dispatch_configured_reviews(project_id, pr_data)
        return
      end

      if pr_data[:phase].in?(%w[draft restarted])
        start_draft_followup_workflow(project_id, pr_data)
      else
        start_pr_followup_workflow(project_id, pr_data)
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

    def passive_review_gate_only?(trigger_types)
      trigger_types.present? &&
        (trigger_types - [ Activities::ScanPaidPrsActivity::PASSIVE_REVIEW_GATE_TRIGGER ]).empty?
    end

    # TODO(#823): Remove patch guard after pre-fix review-dispatch histories continue-as-new.
    def dispatch_configured_reviews(project_id, pr_data)
      pr_number = pr_data[:pr_number]

      if Temporalio::Workflow.patched("dispatch-configured-pr-reviews-v1")
        review_plan = run_activity(Activities::ResolvePrReviewPlanActivity,
          { project_id: project_id }, timeout: 30)

        Array(review_plan[:dispatchable_review_methods]).each do |method|
          request_review_method(project_id, pr_number, method, review_plan)
        end
      else
        # Replay-safe legacy path: reproduces the exact activity inputs that
        # main's handle_review_bot_review_pending recorded. Old histories
        # extracted request_login from the trigger and only requested a review
        # when that login was present; replaying with a hardcoded reviewer
        # would cause non-determinism errors on those histories.
        pending_trigger = (pr_data[:triggers] || []).find { |t| t[:type] == "review_bot_review_pending" }
        login = pending_trigger&.dig(:request_login)

        if login
          request_review(project_id, pr_number, [ login ],
            log_key: "pr_review.request_review_bot_review_failed")
        end
      end
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "pr_review.dispatch_configured_reviews_failed",
        project_id: project_id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def request_review_method(project_id, pr_number, method, review_plan)
      case method
      when "copilot"
        request_review(project_id, pr_number,
          [ Activities::RequestReviewActivity::COPILOT_LOGIN ],
          log_key: "pr_review.request_copilot_review_failed")
      when "paid_agent"
        provider_id = review_plan[:paid_agent_review_provider_id]
        agent_type = review_plan[:paid_agent_review_agent_type]
        unless provider_id.present? && agent_type.present?
          Temporalio::Workflow.logger.warn(
            message: "pr_review.request_review_method_skipped",
            project_id: project_id,
            pr_number: pr_number,
            review_method: method,
            error: "paid_agent review requested without a resolved provider"
          )
          return
        end

        # Queue a dedicated review-goal run on the configured Codex review provider.
        # That workflow posts the GitHub review itself; it does not reuse the project's
        # default coding provider or fall back to Paid's generic create_pr path.
        run_activity(Activities::QueueAgentRunActivity,
          { project_id: project_id, source_pull_request_number: pr_number, goal: "review",
            provider_id: provider_id, agent_type: agent_type },
          timeout: 30)
      end
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "pr_review.request_review_method_failed",
        project_id: project_id,
        pr_number: pr_number,
        review_method: method,
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
      return unless Temporalio::Workflow.patched("add-dev-environment-update-v1")

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

      draft_input = {
        issue_id: issue_id,
        expected_draft_review_count: pr_data[:current_draft_review_count]
      }

      run_activity(Activities::QueueAgentRunActivity,
        { project_id: project_id, issue_id: issue_id,
          source_pull_request_number: pr_number }, timeout: 30)
      run_activity(Activities::RecordDraftReviewActivity, draft_input, timeout: 30)
    end

    def start_pr_followup_workflow(project_id, pr_data)
      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]

      followup_input = {
        project_id: project_id,
        issue_id: issue_id,
        labels_to_remove: pr_data[:labels_to_remove] || [],
        expected_followup_count: pr_data[:current_followup_count]
      }

      run_activity(Activities::QueueAgentRunActivity,
        { project_id: project_id, issue_id: issue_id,
          source_pull_request_number: pr_number }, timeout: 30)
      run_activity(Activities::RecordPrFollowupActivity, followup_input, timeout: 30)
    end
  end
end
