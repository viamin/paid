# frozen_string_literal: true

module Workflows
  # Continuously polls GitHub for labeled issues on a project and triggers
  # agent execution workflows when actionable labels are detected.
  #
  # Runs as a long-lived workflow, sleeping between poll cycles. Can be
  # cancelled via ProjectWorkflowManager.stop_polling.
  class GitHubPollWorkflow < BaseWorkflow
    def execute(input)
      project_id = input[:project_id]

      loop do
        result = run_activity(Activities::FetchIssuesActivity,
          { project_id: project_id }, timeout: 60)

        break if result[:project_missing]

        result[:issues].each do |issue_data|
          detection = run_activity(Activities::DetectLabelsActivity,
            { project_id: project_id, issue_id: issue_data[:id] }, timeout: 30)

          handle_detection(detection, project_id)
        end

        poll_config = run_activity(Activities::GetPollIntervalActivity,
          { project_id: project_id }, timeout: 10)

        break if poll_config[:project_missing]

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
  end
end
