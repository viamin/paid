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
      source_pull_request_number = input[:source_pull_request_number]
      agent_run_id = input[:agent_run_id]
      goal = input.fetch(:goal, "create_pr")

      Temporalio::Workflow.logger.info(
        "AgentExecutionWorkflow started for project=#{project_id} issue=#{issue_id}"
      )

      # Step 1: Create agent run record (or resume a queued one)
      create_input = { project_id: project_id, issue_id: issue_id, agent_type: agent_type,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        agent_run_id: agent_run_id }.compact
      agent_run_result = run_activity(Activities::CreateAgentRunActivity,
        create_input, timeout: 30)
      agent_run_id = agent_run_result[:agent_run_id]
      provider_attempt_count = [ agent_run_result.fetch(:provider_attempt_count, 1), 1 ].max

      begin
        # Step 1.5: Provision service containers (database, redis, etc.)
        # Always run unconditionally — the activity returns {} when no services
        # are configured. Avoids DB queries inside the workflow, which would
        # break Temporal's deterministic replay requirement.
        run_activity(Activities::ProvisionServicesActivity,
          { agent_run_id: agent_run_id }, timeout: 120)

        # Step 2: Provision container (with empty workspace directory)
        run_activity(Activities::ProvisionContainerActivity,
          { agent_run_id: agent_run_id }, timeout: 60)

        # Step 3: Clone repo and create branch inside the container.
        # Skip clone for create_issue goals without a source PR — the agent
        # only needs the GitHub API proxy, not repository code.
        # Review goals always need the repo to examine code.
        skip_clone = goal == "create_issue" && source_pull_request_number.blank?
        unless skip_clone
          run_activity(Activities::CloneRepoActivity,
            { agent_run_id: agent_run_id }, timeout: 180)
        end

        # Step 3b: For existing PR runs without a custom prompt, rebase and build a rich prompt.
        # Skip for review goals — they use their own review-specific prompt and
        # don't need the PR-editing prompt that instructs the agent to commit fixes.
        pr_run_without_prompt = source_pull_request_number.present? && custom_prompt.blank? && goal != "review"
        if pr_run_without_prompt
          rebase_result = run_activity(Activities::RebaseBranchActivity,
            { agent_run_id: agent_run_id }, timeout: 120)

          run_activity(Activities::PreparePrPromptActivity,
            { agent_run_id: agent_run_id,
              rebase_succeeded: rebase_result[:rebase_succeeded] }, timeout: 60)
        end

        # Step 4: Run the agent (long timeout, no retry)
        # Budget based on the expected provider attempts for this run
        # (from CreateAgentRunActivity), plus a small Temporal buffer.
        # Issue goals use a shorter timeout since they only need to create
        # a GitHub issue via curl, not write code.
        per_provider_timeout = if goal == "create_issue"
          Activities::RunAgentActivity::ISSUE_GOAL_TIMEOUT
        else
          Rails.application.config.x.agent_timeout
        end
        activity_timeout = (per_provider_timeout * provider_attempt_count) + 300
        agent_result = run_activity(Activities::RunAgentActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: activity_timeout, retry_policy: NO_RETRY)

        unless agent_result[:success]
          raise Temporalio::Error::ApplicationError.new(
            "Agent execution failed",
            type: "AgentExecutionFailed"
          )
        end

        if goal == "create_issue"
          # Issue goal: check if the agent created an issue via the proxy
          issue_result = run_activity(Activities::CompleteIssueGoalActivity,
            { agent_run_id: agent_run_id }, timeout: 30)

          # Fallback: if the agent didn't create an issue directly, create one
          # from the agent's output using the platform's GitHub integration.
          if issue_result[:issue_created] == false
            # Longer timeout: includes an agent_harness LLM call for title
            # generation, plus GitHub API and DB writes.
            run_activity(Activities::CreateGithubIssueActivity,
              { agent_run_id: agent_run_id }, timeout: 120, retry_policy: NO_RETRY)
          end
        elsif goal == "review"
          # Review goal: complete the run — all output is PR comments posted
          # by the agent via the GitHub API proxy during execution.
          run_activity(Activities::CompleteReviewGoalActivity,
            { agent_run_id: agent_run_id }, timeout: 30)
        elsif agent_result[:has_changes]
          # Step 5: Push branch (inside container)
          run_activity(Activities::PushBranchActivity,
            { agent_run_id: agent_run_id }, timeout: 60)

          if source_pull_request_number
            # Resolve review threads (best-effort, non-fatal)
            if pr_run_without_prompt
              begin
                run_activity(Activities::ResolveReviewThreadsActivity,
                  { agent_run_id: agent_run_id }, timeout: 60)
              rescue => e
                Temporalio::Workflow.logger.warn(
                  message: "agent_execution.resolve_threads_failed",
                  agent_run_id: agent_run_id,
                  error_class: e.class.name,
                  error: e.message
                )
              end
            end

            # Existing PR: mark complete with existing PR details
            complete_result = run_activity(Activities::CompleteExistingPrRunActivity,
              { agent_run_id: agent_run_id }, timeout: 60)

            # Re-request Copilot review if still in draft phase (best-effort)
            if complete_result[:pr_review_phase].in?(%w[draft restarted])
              request_copilot_review(project_id, source_pull_request_number)
            end
          else
            # Step 6: Create PR
            pr_result = run_activity(Activities::CreatePullRequestActivity,
              { agent_run_id: agent_run_id }, timeout: 60)

            # Step 7: Update issue with PR link
            run_activity(Activities::UpdateIssueWithPrActivity,
              { agent_run_id: agent_run_id, pull_request_url: pr_result[:pull_request_url] }, timeout: 30)

            # Step 8: Request Copilot review on the new draft PR (best-effort)
            request_copilot_review(project_id, pr_result[:pull_request_number])
          end
        else
          # No changes - mark as completed without PR
          run_activity(Activities::MarkAgentRunCompleteActivity,
            { agent_run_id: agent_run_id, reason: "no_changes" }, timeout: 30)
        end

        { success: true, agent_run_id: agent_run_id }

      rescue => e
        request_project_resync(project_id) if stale_pull_request_error?(e)

        # Mark agent run as failed.
        # Temporal wraps activity errors in ActivityError — unwrap to get the
        # actual error message from our ApplicationError. Without this, every
        # failure is recorded as the opaque "Activity task failed".
        run_activity(Activities::MarkAgentRunFailedActivity,
          { agent_run_id: agent_run_id, error: unwrap_error_message(e) }, timeout: 30)

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
          run_activity(Activities::CleanupServicesActivity,
            { agent_run_id: agent_run_id },
            start_to_close_timeout: 60, retry_policy: NO_RETRY)
        rescue => e
          Temporalio::Workflow.logger.warn(
            message: "agent_execution.cleanup_services_failed",
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

    private

    # Extracts the meaningful error message from a Temporal exception.
    #
    # When an activity raises ApplicationError, the Temporal SDK wraps it
    # in an ActivityError whose message is the generic "Activity task failed".
    # This method unwraps to the cause's message so we record the actual error.
    def unwrap_error_message(error)
      cause = error.respond_to?(:cause) ? error.cause : nil
      if cause.is_a?(Temporalio::Error::ApplicationError)
        cause.message
      else
        error.message
      end
    end

    def stale_pull_request_error?(error)
      cause = error.respond_to?(:cause) ? error.cause : nil
      cause.is_a?(Temporalio::Error::ApplicationError) && cause.type == "StalePullRequest"
    end

    def request_copilot_review(project_id, pr_number)
      return unless pr_number

      run_activity(Activities::RequestReviewActivity,
        { project_id: project_id, pr_number: pr_number,
          reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] }, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.copilot_review_request_failed",
        project_id: project_id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def request_project_resync(project_id)
      handle = Temporalio::Workflow.external_workflow_handle("github-poll-#{project_id}")
      handle.signal("request_sync")
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.resync_signal_failed",
        project_id: project_id,
        error: e.message
      )
    end
  end
end
