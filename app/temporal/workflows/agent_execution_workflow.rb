# frozen_string_literal: true

module Workflows
  # Orchestrates the complete agent execution lifecycle:
  # worktree creation, container provisioning, agent execution, and PR creation.
  #
  # Called as a child workflow from GitHubPollWorkflow when actionable labels
  # are detected on issues.
  #
  # Steps:
  #   1. Create AgentRun record
  #   2. Create git worktree
  #   3. Provision Docker container
  #   4. Execute agent (with 15-minute timeout)
  #   5. If changes: push branch → create PR → update issue
  #   6. If no changes: mark complete
  #   7. Always: cleanup container and worktree
  class AgentExecutionWorkflow < BaseWorkflow
    NO_RETRY_POLICY = Temporalio::RetryPolicy.new(max_attempts: 1)

    def execute(project_id:, issue_id:, agent_type: "claude_code")
      workflow_info = Temporalio::Workflow.info

      # Step 1: Create agent run record
      agent_run_result = Temporalio::Workflow.execute_activity(
        Activities::CreateAgentRunActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          agent_type: agent_type,
          temporal_workflow_id: workflow_info.workflow_id,
          temporal_run_id: workflow_info.run_id
        },
        **activity_options(timeout: 30)
      )
      agent_run_id = agent_run_result[:agent_run_id]

      begin
        # Step 2: Create worktree
        worktree_result = Temporalio::Workflow.execute_activity(
          Activities::CreateWorktreeActivity,
          { agent_run_id: agent_run_id },
          **activity_options(timeout: 120)
        )
        worktree_path = worktree_result[:worktree_path]

        # Step 3: Provision container
        Temporalio::Workflow.execute_activity(
          Activities::ProvisionContainerActivity,
          { agent_run_id: agent_run_id, worktree_path: worktree_path },
          **activity_options(timeout: 60)
        )

        # Step 4: Run the agent (15-minute timeout, no retries)
        agent_result = Temporalio::Workflow.execute_activity(
          Activities::RunAgentActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: 900,
          retry_policy: NO_RETRY_POLICY
        )

        if agent_result[:has_changes]
          # Step 5: Push branch
          Temporalio::Workflow.execute_activity(
            Activities::PushBranchActivity,
            { agent_run_id: agent_run_id },
            **activity_options(timeout: 60)
          )

          # Step 6: Create PR
          pr_result = Temporalio::Workflow.execute_activity(
            Activities::CreatePullRequestActivity,
            { agent_run_id: agent_run_id },
            **activity_options(timeout: 60)
          )

          # Step 7: Update issue with PR link
          Temporalio::Workflow.execute_activity(
            Activities::UpdateIssueWithPrActivity,
            {
              agent_run_id: agent_run_id,
              pull_request_url: pr_result[:pull_request_url]
            },
            **activity_options(timeout: 30)
          )
        else
          # No changes: mark as completed
          Temporalio::Workflow.execute_activity(
            Activities::MarkAgentRunCompleteActivity,
            { agent_run_id: agent_run_id, reason: "no_changes" },
            **activity_options(timeout: 30)
          )
        end

        { success: true, agent_run_id: agent_run_id }

      rescue => e
        # Mark agent run as failed
        Temporalio::Workflow.execute_activity(
          Activities::MarkAgentRunFailedActivity,
          { agent_run_id: agent_run_id, error: e.message },
          **activity_options(timeout: 30)
        )

        raise

      ensure
        # Always cleanup container and worktree
        Temporalio::Workflow.execute_activity(
          Activities::CleanupContainerActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: 60,
          retry_policy: NO_RETRY_POLICY
        )

        Temporalio::Workflow.execute_activity(
          Activities::CleanupWorktreeActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: 60,
          retry_policy: NO_RETRY_POLICY
        )
      end
    end
  end
end
