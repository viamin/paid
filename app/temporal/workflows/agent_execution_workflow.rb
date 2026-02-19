# frozen_string_literal: true

module Workflows
  # Orchestrates the complete agent execution lifecycle:
  # 1. Create an AgentRun record
  # 2. Provision a Docker container (with empty workspace)
  # 3. Clone repo and create branch inside the container
  # 4. Run the agent to make code changes
  # 5. Push the branch and create a PR (if changes were made)
  # 6. Clean up container and worktree records
  #
  # Git operations (clone, push) run inside the container, authenticated
  # via the git credential helper proxy. No git credentials touch the host.
  #
  # Started as a child workflow from GitHubPollWorkflow when an issue
  # is labeled for agent execution.
  class AgentExecutionWorkflow < BaseWorkflow
    NO_RETRY = Temporalio::RetryPolicy.new(max_attempts: 1)

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      agent_type = input.fetch(:agent_type, "claude_code")
      custom_prompt = input[:custom_prompt]

      Temporalio::Workflow.logger.info(
        "AgentExecutionWorkflow started for project=#{project_id} issue=#{issue_id}"
      )

      # Step 1: Create agent run record
      agent_run_result = run_activity(Activities::CreateAgentRunActivity,
        { project_id: project_id, issue_id: issue_id, agent_type: agent_type,
          custom_prompt: custom_prompt }.compact, timeout: 30)
      agent_run_id = agent_run_result[:agent_run_id]

      begin
        # Step 2: Provision container (with empty workspace directory)
        run_activity(Activities::ProvisionContainerActivity,
          { agent_run_id: agent_run_id }, timeout: 60)

        # Step 3: Clone repo and create branch inside the container
        run_activity(Activities::CloneRepoActivity,
          { agent_run_id: agent_run_id }, timeout: 180)

        # Step 4: Run the agent (long timeout, no retry)
        agent_result = run_activity(Activities::RunAgentActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: 1860, retry_policy: NO_RETRY)

        unless agent_result[:success]
          raise Temporalio::Error::ApplicationError.new(
            "Agent execution failed",
            type: "AgentExecutionFailed"
          )
        end

        if agent_result[:has_changes]
          # Step 5: Push branch (inside container)
          run_activity(Activities::PushBranchActivity,
            { agent_run_id: agent_run_id }, timeout: 60)

          # Step 6: Create PR
          pr_result = run_activity(Activities::CreatePullRequestActivity,
            { agent_run_id: agent_run_id }, timeout: 60)

          # Step 7: Update issue with PR link
          run_activity(Activities::UpdateIssueWithPrActivity,
            { agent_run_id: agent_run_id, pull_request_url: pr_result[:pull_request_url] }, timeout: 30)
        else
          # No changes - mark as completed without PR
          run_activity(Activities::MarkAgentRunCompleteActivity,
            { agent_run_id: agent_run_id, reason: "no_changes" }, timeout: 30)
        end

        { success: true, agent_run_id: agent_run_id }

      rescue => e
        # Mark agent run as failed
        run_activity(Activities::MarkAgentRunFailedActivity,
          { agent_run_id: agent_run_id, error: e.message }, timeout: 30)

        raise

      ensure
        # Always cleanup container (including workspace directory) and worktree DB records.
        # Each cleanup is best-effort: failures are logged but do not
        # mask the primary workflow outcome.
        begin
          run_activity(Activities::CleanupContainerActivity,
            { agent_run_id: agent_run_id },
            start_to_close_timeout: 60, retry_policy: NO_RETRY)
        rescue => e
          Temporalio::Workflow.logger.warn(
            message: "agent_execution.cleanup_container_failed",
            agent_run_id: agent_run_id,
            error_class: e.class.name,
            error: e.message
          )
        end

        begin
          run_activity(Activities::CleanupWorktreeActivity,
            { agent_run_id: agent_run_id },
            start_to_close_timeout: 60, retry_policy: NO_RETRY)
        rescue => e
          Temporalio::Workflow.logger.warn(
            message: "agent_execution.cleanup_worktree_failed",
            agent_run_id: agent_run_id,
            error_class: e.class.name,
            error: e.message
          )
        end
      end
    end
  end
end
