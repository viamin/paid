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
    include Automation::ReviewBotTrigger
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

        record_poll_heartbeat(project_id)

        if Temporalio::Workflow.patched("batch-evaluate-issues-v1")
          evaluate_issues_batch(project_id, result[:issues])
        else
          result[:issues].each do |issue_data|
            evaluation = run_activity(Activities::DetectLabelsActivity,
              { project_id: project_id, issue_id: issue_data[:id] }, timeout: 30)

            handle_automation_result(evaluation, project_id)
          end
        end

        record_poll_heartbeat(project_id)

        maybe_run_non_critical_activities(project_id)

        record_poll_heartbeat(project_id)

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

    # Checks rate limit budget and runs non-critical activities only when
    # sufficient budget remains. Issue detection (FetchIssues + DetectLabels)
    # is prioritized as core work; PR scanning, security alerts, and knowledge
    # staleness checks are skipped when budget is low.
    # TODO(#872): Remove patch guard after all pre-v872 workflows have continued-as-new
    def maybe_run_non_critical_activities(project_id)
      if Temporalio::Workflow.patched("add-rate-limit-budget-v1")
        rate_limit = run_activity(Activities::CheckRateLimitActivity,
          { project_id: project_id }, timeout: 10)

        if rate_limit[:rate_limit_low]
          Temporalio::Workflow.logger.info(
            message: "poll.non_critical_skipped_budget_low",
            project_id: project_id,
            rate_limit_remaining: rate_limit[:rate_limit_remaining]
          )
          return
        end
      end

      maybe_scan_paid_prs(project_id)
      maybe_scan_code_scanning_alerts(project_id)
      maybe_check_knowledge_staleness(project_id)
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

    def handle_automation_result(result, project_id)
      (result[:decisions] || []).each do |decision|
        execute_automation_decision(project_id, decision)
      end
    end

    def execute_automation_decision(project_id, decision)
      case decision[:type]
      when "noop"
        nil
      when "queue_create_pr_run"
        queue_create_pr_run(project_id, decision)
      when "queue_review_run"
        queue_review_run(project_id, decision)
      when "start_planning"
        start_planning_workflow(project_id, decision[:issue_id])
      when "request_review"
        request_review(project_id, decision[:pr_number], decision[:reviewers],
          log_key: "pr_review.request_review_failed")
      when "mark_ready"
        handle_mark_ready(project_id, decision)
      when "escalate"
        handle_escalate_decision(project_id, decision)
      when "dismiss_escalation"
        handle_dismiss_escalation(project_id, decision)
      when "merge"
        handle_owner_approved(project_id, issue_id: decision[:issue_id], pr_number: decision[:pr_number])
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
      end
    end

    def queue_create_pr_run(project_id, decision)
      queue_input = {
        project_id: project_id,
        issue_id: decision[:issue_id],
        source_pull_request_number: decision[:source_pull_request_number],
        goal: "create_pr",
        count_toward_draft_review_round: decision.fetch(:count_toward_draft_review_round, false),
        expected_draft_review_count: decision[:expected_draft_review_count]
      }.compact
      queue_input.delete(:count_toward_draft_review_round) unless queue_input[:count_toward_draft_review_round]

      run_activity(Activities::QueueAgentRunActivity, queue_input, timeout: 30)
    end

    def queue_review_run(project_id, decision)
      run_activity(Activities::QueueAgentRunActivity, {
        project_id: project_id,
        issue_id: decision[:issue_id],
        source_pull_request_number: decision[:source_pull_request_number],
        goal: "review"
      }, timeout: 30)
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
        task_queue: Paid::AGENT_TASK_QUEUE,
        parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
      )
    end

    def handle_pr_scan_results(scan_result, project_id)
      if feature_flag_enabled?(:explicit_pr_automation_decisions, project_id:)
        (scan_result[:automation_results] || []).each do |result|
          handle_automation_result(result, project_id)
        end
        return
      end

      return if scan_result[:prs_to_trigger].blank?

      scan_result[:prs_to_trigger].each do |pr_data|
        handle_pr_trigger(project_id, pr_data)
      end
    end

    def handle_pr_trigger(project_id, pr_data)
      trigger_types = (pr_data[:triggers] || []).map { |t| t[:type] }

      if trigger_types.include?("escalate_to_owner")
        handle_escalate_to_owner(project_id, pr_data)
      elsif trigger_types.include?("dismiss_escalation")
        handle_dismiss_escalation(project_id, pr_data)
      elsif trigger_types.include?("review_goal_retry")
        handle_review_goal_retry(project_id, pr_data)
      elsif trigger_types.include?("ready_for_owner")
        handle_ready_for_owner(project_id, pr_data)
      elsif trigger_types.include?("owner_approved")
        handle_owner_approved(project_id, pr_data)
      elsif trigger_types.include?("paid_agent_review_pending")
        handle_paid_agent_review_pending(project_id, pr_data, trigger_types)
      elsif trigger_types.include?("review_bot_review_pending")
        handle_review_bot_review_pending(project_id, pr_data, trigger_types)
      elsif trigger_types.include?("manual_review_pending") || trigger_types.include?("ci_action_pending")
        # NOTE: when both review_bot_review_pending and manual/ci_action triggers
        # are present, the bot handler above runs first and the non-bot handler is
        # deferred to the next scan cycle. This is intentional — bot review
        # completes before requesting human review or awaiting CI actions.
        handle_non_bot_review_pending(project_id, pr_data, trigger_types)
      elsif pr_data[:phase].in?(%w[draft restarted])
        start_draft_followup_workflow(project_id, pr_data)
      else
        start_pr_followup_workflow(project_id, pr_data)
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
      activity_input = if Temporalio::Workflow.patched("escalation-reason-payload-v1")
        { issue_id: decision[:issue_id], reason: decision[:reason] }.compact
      else
        { issue_id: decision[:issue_id] }
      end

      run_activity(Activities::MarkEscalatedActivity, activity_input, timeout: 30)

      reviewer = decision[:owner_reviewer_login]
      return if reviewer.blank?

      request_review(project_id, decision[:pr_number], [ reviewer ],
        log_key: "pr_review.request_owner_review_failed")
    end

    def handle_ready_for_owner(project_id, pr_data)
      trigger_types = (pr_data[:triggers] || []).map { |t| t[:type] }

      # Queue paid_agent review sidecar if bundled with ready_for_owner
      queue_paid_agent_review_run(project_id, pr_data) if trigger_types.include?("paid_agent_review_pending")

      result = run_activity(Activities::MarkPrReadyActivity,
        { project_id: project_id, pr_number: pr_data[:pr_number],
          issue_id: pr_data[:issue_id] }, timeout: 60)

      return unless result[:marked_ready]

      request_owner_review(project_id, pr_data)
    end

    def handle_escalate_to_owner(project_id, pr_data)
      handle_escalate_decision(project_id,
        issue_id: pr_data[:issue_id],
        pr_number: pr_data[:pr_number],
        owner_reviewer_login: pr_data[:owner_reviewer_login],
        reason: (pr_data[:triggers] || []).find { |t| t[:type] == "escalate_to_owner" }&.dig(:details))
    end

    def handle_dismiss_escalation(project_id, pr_data)
      run_activity(Activities::DismissEscalationActivity,
        { issue_id: pr_data[:issue_id] },
        timeout: 30)
    end

    def request_owner_review(project_id, pr_data)
      reviewer = pr_data[:owner_reviewer_login]
      return if reviewer.blank?

      request_review(project_id, pr_data[:pr_number], [ reviewer ],
        log_key: "pr_review.request_owner_review_failed")
    end

    def handle_paid_agent_review_pending(project_id, pr_data, trigger_types)
      queue_paid_agent_review_run(project_id, pr_data)

      if Temporalio::Workflow.patched("pause-followup-during-review-v1")
        # paid_agent_review_pending is a hard gate: suppress all create_pr
        # follow-up runs while the review for the current head is outstanding.
        # Other triggers (CI failures, merge conflicts, conversation comments)
        # will be re-detected on the next scan cycle after the review completes
        # and any resulting code changes are made. (#1135)
        return nil
      end

      other_triggers = trigger_types - [ "paid_agent_review_pending" ]

      if other_triggers.empty?
        # paid_agent_review_pending as sole trigger means no code changes are
        # needed — the review queue above is the only action. When the scanner
        # detects unaddressed review findings it emits review_bot_comments
        # alongside, which routes through handle_review_bot_review_pending
        # with a create_pr follow-up instead (#1152).
        nil
      elsif pr_data[:phase].in?(%w[draft restarted])
        start_draft_followup_workflow(project_id, pr_data)
      else
        start_pr_followup_workflow(project_id, pr_data)
      end
    end

    def queue_paid_agent_review_run(project_id, pr_data)
      return unless Temporalio::Workflow.patched("queue-paid-agent-review-run-v1")

      pending_trigger = (pr_data[:triggers] || []).find { |t| t[:type] == "paid_agent_review_pending" }
      return if pending_trigger&.dig(:active_run)

      run_activity(Activities::QueueAgentRunActivity,
        { project_id: project_id, issue_id: pr_data[:issue_id],
          source_pull_request_number: pr_data[:pr_number],
          goal: "review" }, timeout: 30)
    end

    def handle_review_bot_review_pending(project_id, pr_data, trigger_types)
      if Temporalio::Workflow.patched("pause-review-bot-followup-during-review-v1")
        dispatch_review_bot_review_request(project_id, pr_data)

        # review_bot_review_pending is a hard gate: suppress all create_pr
        # follow-up runs while a bot review is outstanding, mirroring the
        # paid_agent_review_pending hard gate from #1135. Other triggers
        # (CI failures, merge conflicts, conversation comments) will be
        # re-detected on the next scan cycle after the review completes
        # and any resulting code changes are made. (#1336)
        return nil
      end

      other_triggers = trigger_types - [ "review_bot_review_pending" ]

      if pr_data[:phase].in?(%w[draft restarted])
        dispatch_review_bot_review_request(project_id, pr_data)
        return if other_triggers.empty?

        start_draft_followup_workflow(project_id, pr_data)
        return
      end

      return dispatch_review_bot_review_request(project_id, pr_data) if other_triggers.empty?

      start_pr_followup_workflow(project_id, pr_data)
    end

    def dispatch_review_bot_review_request(project_id, pr_data)
      # Use the chain from the trigger: an empty list means the bot
      # auto-reviews (e.g. Codex via GitHub App) and no explicit request is
      # needed. The full chain is forwarded to RequestReviewActivity so it
      # can fall through to a configured secondary bot when the primary is
      # rate-limited or unavailable.
      pending_trigger = (pr_data[:triggers] || []).find { |t| t[:type] == "review_bot_review_pending" }
      reviewers = review_bot_reviewers_from(pending_trigger)
      return if reviewers.empty?

      request_review(project_id, pr_data[:pr_number],
        reviewers,
        log_key: "pr_review.request_review_bot_review_failed")
    end

    def handle_review_goal_retry(project_id, pr_data)
      trigger_types = (pr_data[:triggers] || []).map { |t| t[:type] }

      if trigger_types.include?("owner_approved")
        handle_owner_approved(project_id, pr_data)
        return
      end

      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]

      run_activity(Activities::RecordReviewGoalRetryActivity,
        { issue_id: issue_id,
          expected_review_goal_retry_count: pr_data[:current_review_goal_retry_count] },
        timeout: 30)

      run_activity(Activities::QueueAgentRunActivity, {
        project_id: project_id,
        issue_id: issue_id,
        source_pull_request_number: pr_number,
        goal: "review"
      }, timeout: 30)

      if trigger_types.include?("ready_for_owner")
        without_paid_agent_review = pr_data[:triggers].reject { |t| t[:type] == "paid_agent_review_pending" }
        handle_ready_for_owner(project_id, pr_data.merge(triggers: without_paid_agent_review))
        return
      end

      dispatch_manual_review_request(project_id, pr_data)

      followup_trigger_types = %w[
        ci_failure review_threads conversation_comments changes_requested
        actionable_labels merge_conflicts review_bot_comments review_bot_threads
      ]
      followup_triggers = (pr_data[:triggers] || []).any? { |t| followup_trigger_types.include?(t[:type]) }

      if followup_triggers
        if pr_data[:phase].in?(%w[draft restarted])
          start_draft_followup_workflow(project_id, pr_data)
        else
          start_pr_followup_workflow(project_id, pr_data)
        end
      else
        dispatch_bot_review_request(project_id, pr_data)
      end
    end

    def dispatch_manual_review_request(project_id, pr_data)
      manual = (pr_data[:triggers] || []).find { |t| t[:type] == "manual_review_pending" }
      return unless manual

      login = manual[:reviewer_login]
      return unless login

      request_review(project_id, pr_data[:pr_number],
        [ login ],
        log_key: "pr_review.request_manual_review_failed")
    end

    def dispatch_bot_review_request(project_id, pr_data)
      pending_bot = (pr_data[:triggers] || []).find { |t| t[:type] == "review_bot_review_pending" }
      reviewers = review_bot_reviewers_from(pending_bot)
      return if reviewers.empty?

      request_review(project_id, pr_data[:pr_number],
        reviewers,
        log_key: "pr_review.request_review_bot_review_failed")
    end

    def handle_non_bot_review_pending(project_id, pr_data, trigger_types)
      # For manual_review_pending, request a review from the configured reviewer.
      # For ci_action_pending, dispatch the Claude review workflow only when
      # the trigger explicitly asks for it; otherwise the PR simply waits for
      # the existing check run to finish.
      manual_trigger = (pr_data[:triggers] || []).find { |t| t[:type] == "manual_review_pending" }
      if manual_trigger
        login = manual_trigger[:reviewer_login]
        if login.present?
          request_review(project_id, pr_data[:pr_number],
            [ login ],
            log_key: "pr_review.request_manual_review_failed")
        end
      end

      ci_action_trigger = (pr_data[:triggers] || []).find { |t| t[:type] == "ci_action_pending" }
      if ci_action_trigger&.dig(:dispatch_required)
        run_activity(Activities::DispatchClaudeReviewActivity,
          { project_id: project_id, pr_number: pr_data[:pr_number] }, timeout: 60)
      end

      # If there are other actionable triggers beyond the non-bot gates,
      # start a followup workflow to address them.
      other_triggers = trigger_types - %w[manual_review_pending ci_action_pending]
      return if other_triggers.empty?

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

      # TODO(#220): Remove patch guard after all long-running GitHubPollWorkflows
      # have continued-as-new past this point (i.e. no workflow history contains
      # the legacy queue-then-record command sequence).
      unless Temporalio::Workflow.patched("draft-followup-direct-start-v1")
        legacy_input = { project_id: project_id, issue_id: issue_id,
          source_pull_request_number: pr_number }
        legacy_input[:goal] = "create_pr" if Temporalio::Workflow.patched("queue-agent-run-goal-v1")
        run_activity(Activities::QueueAgentRunActivity, legacy_input, timeout: 30)
        run_activity(Activities::RecordDraftReviewActivity,
          {
            issue_id: issue_id,
            expected_draft_review_count: pr_data[:current_draft_review_count]
          }, timeout: 30)
        return
      end

      draft_input = {
        project_id: project_id,
        issue_id: issue_id,
        source_pull_request_number: pr_number,
        count_toward_draft_review_round: true,
        expected_draft_review_count: pr_data[:current_draft_review_count]
      }
      draft_input[:goal] = "create_pr" if Temporalio::Workflow.patched("queue-agent-run-goal-v1")
      run_activity(Activities::QueueAgentRunActivity, draft_input, timeout: 30)
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

      followup_queue_input = { project_id: project_id, issue_id: issue_id,
        source_pull_request_number: pr_number }
      followup_queue_input[:goal] = "create_pr" if Temporalio::Workflow.patched("queue-agent-run-goal-v1")
      run_activity(Activities::QueueAgentRunActivity, followup_queue_input, timeout: 30)
      run_activity(Activities::RecordPrFollowupActivity, followup_input, timeout: 30)
    end
  end
end
