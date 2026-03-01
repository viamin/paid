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

        # Scan paid-generated PRs for follow-up work
        scan_result = run_activity(Activities::ScanPaidPrsActivity,
          { project_id: project_id }, timeout: 120)

        handle_pr_scan_results(scan_result, project_id)

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

    def handle_detection(detection, project_id)
      case detection[:action]
      when "execute_agent"
        start_agent_workflow(project_id, detection[:issue_id])
      when "start_planning"
        start_agent_workflow(project_id, detection[:issue_id], prefix: "plan")
      end
    end

    # When at capacity, queues an AgentRun record (no child workflow). ProcessRunQueueJob
    # will start the workflow when a slot opens. This asymmetry is intentional: queued
    # runs don't need workflow-level monitoring since the DB record tracks their state.
    def start_agent_workflow(project_id, issue_id, prefix: "agent")
      capacity = run_activity(Activities::CheckRunCapacityActivity, {}, timeout: 10)

      unless capacity[:has_capacity]
        run_activity(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: issue_id }, timeout: 30)
        return
      end

      workflow_id = "#{prefix}-#{project_id}-#{issue_id}-#{Temporalio::Workflow.now.to_i}"

      Temporalio::Workflow.start_child_workflow(
        Workflows::AgentExecutionWorkflow,
        { project_id: project_id, issue_id: issue_id },
        id: workflow_id
      )
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
      elsif pr_data[:phase] == "draft"
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
        { issue_id: pr_data[:issue_id] }, timeout: 30)

      request_owner_review(project_id, pr_data)
    end

    def request_owner_review(project_id, pr_data)
      reviewer = pr_data[:owner_reviewer_login]
      return if reviewer.blank?

      begin
        run_activity(Activities::RequestReviewActivity,
          { project_id: project_id, pr_number: pr_data[:pr_number],
            reviewers: [ reviewer ] }, timeout: 60)
      rescue Temporalio::Error::CanceledError
        raise
      rescue => e
        Temporalio::Workflow.logger.warn(
          message: "pr_review.request_owner_review_failed",
          project_id: project_id,
          pr_number: pr_data[:pr_number],
          error: e.message
        )
      end
    end

    def handle_owner_approved(project_id, pr_data)
      run_activity(Activities::MergePullRequestActivity,
        { project_id: project_id, pr_number: pr_data[:pr_number],
          issue_id: pr_data[:issue_id] }, timeout: 60)
    end

    def start_draft_followup_workflow(project_id, pr_data)
      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]

      capacity = run_activity(Activities::CheckRunCapacityActivity, {}, timeout: 10)

      draft_input = {
        issue_id: issue_id,
        expected_draft_review_count: pr_data[:current_draft_review_count]
      }

      unless capacity[:has_capacity]
        run_activity(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: issue_id,
            source_pull_request_number: pr_number }, timeout: 30)

        run_activity(Activities::RecordDraftReviewActivity, draft_input, timeout: 30)
        return
      end

      timestamp = Temporalio::Workflow.now.to_i
      workflow_id = "draft-followup-#{project_id}-#{pr_number}-#{timestamp}"

      Temporalio::Workflow.start_child_workflow(
        Workflows::AgentExecutionWorkflow,
        {
          project_id: project_id,
          issue_id: issue_id,
          source_pull_request_number: pr_number
        },
        id: workflow_id
      )

      run_activity(Activities::RecordDraftReviewActivity, draft_input, timeout: 30)
    end

    def start_pr_followup_workflow(project_id, pr_data)
      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]

      capacity = run_activity(Activities::CheckRunCapacityActivity, {}, timeout: 10)

      followup_input = {
        project_id: project_id,
        issue_id: issue_id,
        labels_to_remove: pr_data[:labels_to_remove] || [],
        expected_followup_count: pr_data[:current_followup_count]
      }

      unless capacity[:has_capacity]
        run_activity(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: issue_id,
            source_pull_request_number: pr_number }, timeout: 30)

        run_activity(Activities::RecordPrFollowupActivity, followup_input, timeout: 30)
        return
      end

      timestamp = Temporalio::Workflow.now.to_i
      workflow_id = "pr-followup-#{project_id}-#{pr_number}-#{timestamp}"

      Temporalio::Workflow.start_child_workflow(
        Workflows::AgentExecutionWorkflow,
        {
          project_id: project_id,
          issue_id: issue_id,
          source_pull_request_number: pr_number
        },
        id: workflow_id
      )

      run_activity(Activities::RecordPrFollowupActivity, followup_input, timeout: 30)
    end
  end
end
