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

    # RunAgentActivity uses a limited retry policy so Temporal can reschedule
    # the activity on a new worker when the original worker dies (detected via
    # heartbeat timeout). Application-level errors are marked non_retryable in
    # the activity itself, so only infrastructure failures (worker crash,
    # heartbeat timeout) trigger a retry.
    RUN_AGENT_RETRY_POLICY = Temporalio::RetryPolicy.new(
      max_attempts: 2,
      initial_interval: 5,
      max_interval: 5
    )

    CLEANUP_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: 2,
      max_interval: 15,
      backoff_coefficient: 2,
      max_attempts: 5
    )

    # The proxy health check activity performs a single HTTP check per
    # invocation and raises a retryable error when unhealthy. Temporal
    # manages backoff/retry via this policy (5s initial → 30s cap), freeing
    # the activity worker thread between attempts. When schedule_to_close
    # expires (MAX_WAIT_SECONDS), the workflow converts the timeout to a
    # non-retryable ProxyUnavailable error.
    PROXY_HEALTH_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: Activities::CheckProxyHealthActivity::INITIAL_POLL_INTERVAL,
      max_interval: Activities::CheckProxyHealthActivity::MAX_POLL_INTERVAL,
      backoff_coefficient: Activities::CheckProxyHealthActivity::BACKOFF_MULTIPLIER,
      max_attempts: 0 # unlimited — schedule_to_close_timeout is the deadline
    )
    PROXY_HEALTH_TIMEOUT = Activities::CheckProxyHealthActivity::MAX_WAIT_SECONDS

    # Error types from activities where the agent never produced useful work
    # or the outcome is expected/recoverable — containers are cleaned up
    # immediately for these rather than retained for diagnostics.
    KNOWN_FAILURE_TYPES = %w[
      AllProvidersExhausted
      AgentExecutionFailed
      MissingPrompt
      MissingUser
      ContainerNotProvisioned
      ProxyUnavailable
      RateLimit
    ].freeze

    # Non-ApplicationError exception classes that represent expected/recoverable
    # failures and should not trigger container retention.
    KNOWN_FAILURE_CLASSES = [
      "GithubClient::RateLimitError",
      "GithubClient::AuthenticationError"
    ].freeze

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
        agent_run_id: agent_run_id, goal: goal }.compact
      agent_run_result = run_activity(Activities::CreateAgentRunActivity,
        create_input, timeout: 30)
      agent_run_id = agent_run_result[:agent_run_id]
      provider_attempt_count = [ agent_run_result.fetch(:provider_attempt_count, 1), 1 ].max
      agent_timeout_seconds = agent_run_result.fetch(:agent_timeout_seconds, AGENT_TIMEOUT_DEFAULT)
      issue_goal_timeout_seconds = agent_run_result.fetch(
        :issue_goal_timeout_seconds,
        Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT
      )

      agent_step_succeeded = false
      workflow_error = nil

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

        # Step 2b: Verify the credential proxy is healthy before git operations.
        # Clone and push depend on the proxy for git authentication. When the
        # Rails app is down (e.g. PendingMigration), the proxy is unreachable
        # and git operations fail. This check polls until the proxy recovers,
        # effectively pausing the workflow until credentials are available.
        skip_clone = goal == "create_issue" && source_pull_request_number.blank?
        unless skip_clone
          Temporalio::Workflow.patched("check_proxy_health_before_clone") do
            ensure_proxy_healthy(agent_run_id)
          end
        end

        # Step 3: Clone repo and create branch inside the container.
        # Skip clone for create_issue goals without a source PR — the agent
        # only needs the GitHub API proxy, not repository code.
        # Review goals always need the repo to examine code.
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

        # Step 4: Run the agent (long timeout, limited retry for worker recovery)
        # Budget based on the expected provider attempts for this run
        # (from CreateAgentRunActivity), plus a small Temporal buffer.
        # Issue goals use a shorter timeout since they only need to create
        # a GitHub issue via curl, not write code.
        per_provider_timeout = if goal == "create_issue"
          issue_goal_timeout_seconds
        else
          agent_timeout_seconds
        end
        activity_timeout = (per_provider_timeout * provider_attempt_count) + 300
        agent_result = run_activity(Activities::RunAgentActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: activity_timeout,
          heartbeat_timeout: 120,
          retry_policy: RUN_AGENT_RETRY_POLICY)

        unless agent_result[:success]
          raise Temporalio::Error::ApplicationError.new(
            "Agent execution failed",
            type: "AgentExecutionFailed"
          )
        end

        agent_step_succeeded = true

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
            { agent_run_id: agent_run_id }, timeout: 30, retry_policy: NO_RETRY)
        elsif agent_result[:has_changes]
          # Step 5: Push branch (inside container)
          # Re-check proxy health before push — the agent may have run for
          # a long time and the proxy could have gone down in the meantime.
          Temporalio::Workflow.patched("check_proxy_health_before_push") do
            ensure_proxy_healthy(agent_run_id)
          end

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

            # New commits invalidate prior bot feedback, so request a fresh
            # Copilot review for any still-active PR phase.
            if complete_result[:pr_review_phase].in?(%w[draft restarted ready escalated])
              request_copilot_review(project_id, source_pull_request_number)
            end

            # Draft a decision record for existing PR changes (best-effort)
            draft_decision_record(agent_run_id)
          else
            # Step 6: Create PR
            pr_result = run_activity(Activities::CreatePullRequestActivity,
              { agent_run_id: agent_run_id }, timeout: 60)

            # Step 7: Update issue with PR link
            run_activity(Activities::UpdateIssueWithPrActivity,
              { agent_run_id: agent_run_id, pull_request_url: pr_result[:pull_request_url] }, timeout: 30)

            # Step 8: Request Copilot review on the new draft PR (best-effort)
            request_copilot_review(project_id, pr_result[:pull_request_number])

            # Step 9: Draft a decision record (best-effort)
            draft_decision_record(agent_run_id)
          end
        else
          # No changes produced by agent
          if issue_id.present? && !source_pull_request_number
            # Issue-based run with no code changes / no PR: classify as
            # needs_input or recommend_close and post an actionable GitHub comment.
            run_activity(Activities::HandleNoOutputIssueRunActivity,
              { agent_run_id: agent_run_id,
                output_present: agent_result.fetch(:output_present, false) }, timeout: 30)
          else
            # Non-issue run or existing-PR run: mark completed
            run_activity(Activities::MarkAgentRunCompleteActivity,
              { agent_run_id: agent_run_id, reason: "no_changes" }, timeout: 30)
          end

          # Still request Copilot review for existing PR runs: the previous
          # run may have pushed a fix that Copilot hasn't reviewed yet.
          if source_pull_request_number
            request_copilot_review(project_id, source_pull_request_number)
          end
        end

        { success: true, agent_run_id: agent_run_id }

      rescue => e
        workflow_error = e
        request_project_resync(project_id) if stale_pull_request_error?(e)

        # Mark agent run as failed.
        # Temporal wraps activity errors in ActivityError — unwrap to get the
        # actual error message from our ApplicationError. Without this, every
        # failure is recorded as the opaque "Activity task failed".
        run_activity(Activities::MarkAgentRunFailedActivity,
          { agent_run_id: agent_run_id, error: unwrap_error_message(e) }, timeout: 30)

        raise

      ensure
        # Cleanup container (including workspace directory) and worktree DB records.
        # Each cleanup retries transient Docker failures (up to 5 attempts with exponential
        # backoff). Per-attempt timeout is 120s; schedule_to_close_timeout caps total wall
        # time per cleanup activity at 5 minutes to prevent the ensure block from stalling.
        # Failures are logged but do not mask the primary workflow outcome.
        #
        # When the agent step completed successfully but the workflow failed for an
        # unknown reason (e.g. push or PR creation failure), retain the container
        # temporarily for diagnostics and possible work recovery.
        #
        # Skip cleanup activities when agent_run_id is not present — calling
        # AgentRun.find(nil) would raise and waste retry budget on a known no-op.
        if agent_run_id.present?
          retain = should_retain_container?(agent_step_succeeded, workflow_error)

          if retain
            begin
              retain_result = run_activity(Activities::RetainContainerActivity,
                { agent_run_id: agent_run_id },
                start_to_close_timeout: 30, schedule_to_close_timeout: 120,
                retry_policy: Temporalio::RetryPolicy.new(max_attempts: 3, initial_interval: 1))
              # Only skip cleanup if the activity explicitly reports the container was retained.
              retain = retain_result.is_a?(Hash) && retain_result[:retained] == true
            rescue => e
              Temporalio::Workflow.logger.warn(
                message: "agent_execution.retain_container_failed",
                agent_run_id: agent_run_id,
                error_class: e.class.name,
                error: e.message
              )
              # Fall through to normal cleanup if retention fails
              retain = false
            end
          end

          unless retain
            begin
              run_activity(Activities::CleanupContainerActivity,
                { agent_run_id: agent_run_id },
                start_to_close_timeout: 120, schedule_to_close_timeout: 300,
                retry_policy: CLEANUP_RETRY_POLICY)
            rescue => e
              Temporalio::Workflow.logger.warn(
                message: "agent_execution.cleanup_container_failed",
                agent_run_id: agent_run_id,
                error_class: e.class.name,
                error: e.message
              )
            end
          end

          begin
            run_activity(Activities::CleanupServicesActivity,
              { agent_run_id: agent_run_id },
              start_to_close_timeout: 120, schedule_to_close_timeout: 300,
              retry_policy: CLEANUP_RETRY_POLICY)
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
              start_to_close_timeout: 120, schedule_to_close_timeout: 300,
              retry_policy: CLEANUP_RETRY_POLICY)
          rescue => e
            Temporalio::Workflow.logger.warn(
              message: "agent_execution.cleanup_worktree_failed",
              agent_run_id: agent_run_id,
              error_class: e.class.name,
              error: e.message
            )
          end
        end

        # Enqueue a janitor job as a second cleanup pass outside the workflow
        # lifecycle. If the retries above succeeded this is a no-op; if they
        # failed the janitor provides another attempt at cleanup outside the workflow.
        # For retained containers the janitor respects the retention TTL.
        begin
          if agent_run_id.present?
            run_activity(Activities::EnqueueJanitorActivity,
              { agent_run_id: agent_run_id },
              start_to_close_timeout: 10,
              retry_policy: Temporalio::RetryPolicy.new(max_attempts: 3, initial_interval: 1))
          end
        rescue => e
          Temporalio::Workflow.logger.warn(
            message: "agent_execution.enqueue_janitor_failed",
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

    def draft_decision_record(agent_run_id)
      run_activity(Activities::DraftDecisionRecordActivity,
        { agent_run_id: agent_run_id }, timeout: 60, retry_policy: NO_RETRY)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.draft_decision_record_failed",
        agent_run_id: agent_run_id,
        error: e.message,
        error_class: e.class.name
      )
    end

    # Determines whether the container should be retained for diagnostics
    # instead of immediate cleanup. Only retains when:
    #   1. The agent step completed successfully (produced potentially useful work)
    #   2. The workflow failed (there's something to diagnose)
    #   3. The failure is not a known/expected outcome
    def should_retain_container?(agent_step_succeeded, workflow_error)
      return false unless agent_step_succeeded
      return false unless workflow_error

      # Walk the error cause chain looking for cancellations, known
      # ApplicationError types, and known exception classes.
      # Cancellations can be wrapped (e.g. ActivityError whose cause is
      # CanceledError), so we check at every level rather than only the
      # top-level error.
      current_error = workflow_error
      while current_error
        return false if current_error.is_a?(Temporalio::Error::CanceledError)

        if current_error.is_a?(Temporalio::Error::ApplicationError)
          # For ApplicationError, the underlying exception type is carried in
          # `type`, so compare both known failure *types* and *classes* against it.
          return false if KNOWN_FAILURE_TYPES.include?(current_error.type)
          return false if KNOWN_FAILURE_CLASSES.include?(current_error.type)
        else
          # For non-ApplicationError exceptions, compare against the Ruby class name.
          return false if KNOWN_FAILURE_CLASSES.include?(current_error.class.name)
        end

        break unless current_error.respond_to?(:cause)
        current_error = current_error.cause
      end

      true
    end

    # Design: The activity performs a single health check per invocation and
    # raises a retryable ProxyUnhealthy error when the proxy is down. Temporal
    # manages backoff/retry via PROXY_HEALTH_RETRY_POLICY (5s → 30s cap),
    # keeping the activity worker thread free between attempts. When the
    # schedule_to_close_timeout expires, Temporal surfaces a TimeoutError
    # which this method converts to a non-retryable ProxyUnavailable.
    def ensure_proxy_healthy(agent_run_id)
      run_activity(Activities::CheckProxyHealthActivity,
        { agent_run_id: agent_run_id },
        start_to_close_timeout: 30,
        schedule_to_close_timeout: PROXY_HEALTH_TIMEOUT,
        retry_policy: PROXY_HEALTH_RETRY_POLICY)
    rescue Temporalio::Error::ActivityError => e
      raise unless e.cause.is_a?(Temporalio::Error::TimeoutError)

      raise Temporalio::Error::ApplicationError.new(
        "Credential proxy unavailable after #{PROXY_HEALTH_TIMEOUT}s",
        type: "ProxyUnavailable",
        non_retryable: true
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
