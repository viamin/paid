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

    def execute(input)
      project_id = input[:project_id]
      iterations = 0

      loop do
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

        Temporalio::Workflow.sleep(poll_config[:poll_interval_seconds])
      end
    end

    private

    def handle_detection(detection, project_id)
      case detection[:action]
      when "execute_agent"
        start_agent_workflow(project_id, detection[:issue_id])
      when "start_planning"
        start_agent_workflow(project_id, detection[:issue_id], prefix: "plan")
      end
    end

    def start_agent_workflow(project_id, issue_id, prefix: "agent")
      workflow_id = "#{prefix}-#{project_id}-#{issue_id}-#{Temporalio::Workflow.current_time.to_i}"

      Temporalio::Workflow.start_child_workflow(
        Workflows::AgentExecutionWorkflow,
        { project_id: project_id, issue_id: issue_id },
        id: workflow_id
      )
    end

    def handle_pr_scan_results(scan_result, project_id)
      return if scan_result[:prs_to_trigger].blank?

      scan_result[:prs_to_trigger].each do |pr_data|
        start_pr_followup_workflow(project_id, pr_data)
      end
    end

    def start_pr_followup_workflow(project_id, pr_data)
      issue_id = pr_data[:issue_id]
      pr_number = pr_data[:pr_number]
      timestamp = Temporalio::Workflow.current_time.to_i
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
    end
  end
end
