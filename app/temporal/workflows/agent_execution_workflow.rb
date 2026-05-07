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
      IssueDraftInvalid
      McpProvisioningFailed
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
      agent_type = input[:agent_type]
      custom_prompt = input[:custom_prompt]
      source_pull_request_number = input[:source_pull_request_number]
      agent_run_id = input[:agent_run_id]
      goal = input.fetch(:goal, "create_pr")

      Temporalio::Workflow.logger.info(
        "AgentExecutionWorkflow started for project=#{project_id} issue=#{issue_id}"
      )

      parent_workflow_id = input[:parent_workflow_id]

      # Step 1: Create agent run record (or resume a queued one)
      # Pass the workflow ID so newly-created runs store the real Temporal
      # workflow ID rather than CLAIMED_SENTINEL (which is only a pre-start
      # claim marker used by the queue).
      create_input = { project_id: project_id, issue_id: issue_id, agent_type: agent_type,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        agent_run_id: agent_run_id, goal: goal,
        parent_workflow_id: parent_workflow_id,
        workflow_id: current_workflow_id,
        count_toward_draft_review_round: input[:count_toward_draft_review_round],
        expected_draft_review_count: input[:expected_draft_review_count] }.compact
      agent_run_result = run_activity(Activities::CreateAgentRunActivity,
        create_input, timeout: 30)
      agent_run_id = agent_run_result[:agent_run_id]
      provider_attempt_count = [ agent_run_result.fetch(:provider_attempt_count, 1), 1 ].max
      agent_timeout_seconds = agent_run_result.fetch(:agent_timeout_seconds, AGENT_TIMEOUT_DEFAULT)
      issue_goal_timeout_seconds = agent_run_result.fetch(
        :issue_goal_timeout_seconds,
        Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT
      )
      max_execution_seconds = agent_run_result[:max_execution_seconds]

      agent_step_succeeded = false
      workflow_error = nil

      begin
        if Temporalio::Workflow.patched("agent-execution-quality-gate-v1")
          gate_result = check_quality_gate(
            project_id: project_id,
            issue_id: issue_id,
            agent_run_id: agent_run_id,
            source_pull_request_number: source_pull_request_number
          )
          unless gate_result.fetch(:allowed, true)
            run_activity(Activities::MarkAgentRunFailedActivity,
              { agent_run_id: agent_run_id, error: quality_gate_error(gate_result) }, timeout: 30)

            return { success: false, quality_gate_blocked: true, agent_run_id: agent_run_id }
          end
        end

        if goal == "enhance_issue"
          run_activity(Activities::EnhanceIssueActivity,
            { agent_run_id: agent_run_id },
            start_to_close_timeout: 300,
            retry_policy: NO_RETRY)

          agent_step_succeeded = true
          return { success: true, agent_run_id: agent_run_id }
        end

        if goal == "analyze_issue"
          result = run_activity(Activities::AnalyzeIssueActivity,
            { agent_run_id: agent_run_id },
            start_to_close_timeout: issue_goal_timeout_seconds,
            retry_policy: NO_RETRY)

          agent_step_succeeded = true
          return { success: true, agent_run_id: agent_run_id, **result.slice(:sufficient_context) }
        end

        # Step 1.5: Provision service containers (database, redis, etc.)
        # Always run unconditionally — the activity returns {} when no services
        # are configured. Avoids DB queries inside the workflow, which would
        # break Temporal's deterministic replay requirement.
        run_activity(Activities::ProvisionServicesActivity,
          { agent_run_id: agent_run_id }, timeout: 120)

        # Step 1.6: Provision MCP servers (npx stdio + docker_image sidecars).
        # Always run unconditionally — returns empty lists when no MCP servers
        # are configured. Must run before container provisioning so sidecar
        # URLs are available when the agent starts.
        if Temporalio::Workflow.patched("provision_mcp_servers_v1")
          run_activity(Activities::ProvisionMcpServersActivity,
            { agent_run_id: agent_run_id }, timeout: 120)
        end

        # Step 2: Provision container (with empty workspace directory)
        run_activity(Activities::ProvisionContainerActivity,
          { agent_run_id: agent_run_id }, timeout: 60)

        # Step 2b: Verify the credential proxy is healthy before git operations.
        # Clone and push depend on the proxy for git authentication. When the
        # Rails app is down (e.g. PendingMigration), the proxy is unreachable
        # and git operations fail. This check polls until the proxy recovers,
        # effectively pausing the workflow until credentials are available.
        skip_clone = goal.in?(%w[create_issue enhance_issue analyze_issue]) && source_pull_request_number.blank?
        unless skip_clone
          if Temporalio::Workflow.patched("check_proxy_health_before_clone")
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
        pr_prompt_result = {}
        branch_changed_before_agent = false
        if pr_run_without_prompt
          rebase_result = run_activity(Activities::RebaseBranchActivity,
            { agent_run_id: agent_run_id }, timeout: 120)
          branch_changed_before_agent = rebase_result[:branch_changed] == true

          pr_prompt_result = run_activity(Activities::PreparePrPromptActivity,
            { agent_run_id: agent_run_id,
              rebase_succeeded: rebase_result[:rebase_succeeded] }, timeout: 60)
        end

        # Step 4: Run the agent (long timeout, limited retry for worker recovery)
        # Budget based on the expected provider attempts for this run
        # (from CreateAgentRunActivity), plus a small Temporal buffer.
        # Issue goals use a shorter timeout since they only need to create
        # a GitHub issue via curl, not write code.
        per_provider_timeout = if goal.in?(%w[create_issue enhance_issue analyze_issue])
          issue_goal_timeout_seconds
        else
          agent_timeout_seconds
        end
        activity_timeout = (per_provider_timeout * provider_attempt_count) + 300

        # Cap the activity timeout by the project's max execution time limit
        # (plus a buffer for Temporal overhead). This ensures runs are terminated
        # even when the per-provider timeout budget is larger.
        if max_execution_seconds
          execution_limit = max_execution_seconds + 300
          activity_timeout = [ activity_timeout, execution_limit ].min
        end
        agent_result = run_activity(Activities::RunAgentActivity,
          { agent_run_id: agent_run_id },
          start_to_close_timeout: activity_timeout,
          heartbeat_timeout: 120,
          retry_policy: RUN_AGENT_RETRY_POLICY)

        if agent_result[:paused]
          return { success: false, paused: true, agent_run_id: agent_run_id }
        end

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
          if issue_result[:issue_created] == false && !issue_result[:skipped]
            # Check for cross-repo issue plan before falling back to single-issue creation
            cross_repo_result = run_activity(Activities::ParseCrossRepoIssuePlanActivity,
              { agent_run_id: agent_run_id }, timeout: 30, retry_policy: NO_RETRY)

            plan = cross_repo_result[:plan]

            if plan
              create_cross_repo_issue_pair(agent_run_id, plan)
            else
              # Check for multi-issue decomposition plan before falling back to single-issue creation
              multi_issue_result = run_activity(Activities::ParseMultiIssuePlanActivity,
                { agent_run_id: agent_run_id }, timeout: 30, retry_policy: NO_RETRY)

              multi_plan = multi_issue_result[:plan]

              if multi_plan
                create_multiple_issues(agent_run_id, multi_plan)
              else
                # Longer timeout: includes an agent_harness LLM call for title
                # generation, plus GitHub API and DB writes.
                run_activity(Activities::CreateGithubIssueActivity,
                  { agent_run_id: agent_run_id }, timeout: 120, retry_policy: NO_RETRY)
              end
            end
          end
        elsif goal == "review"
          # Review goal: complete the run — all output is PR comments posted
          # by the agent via the GitHub API proxy during execution.
          run_activity(Activities::CompleteReviewGoalActivity,
            { agent_run_id: agent_run_id }, timeout: 30, retry_policy: NO_RETRY)
        elsif agent_result[:has_changes] || branch_changed_before_agent
          # Step 5: Push branch (inside container)
          # Re-check proxy health before push — the agent may have run for
          # a long time and the proxy could have gone down in the meantime.
          if Temporalio::Workflow.patched("check_proxy_health_before_push")
            ensure_proxy_healthy(agent_run_id)
          end

          run_activity(Activities::PushBranchActivity,
            { agent_run_id: agent_run_id }, timeout: 60)

          if source_pull_request_number
            # Resolve review threads (best-effort, non-fatal)
            resolve_followup_review_threads_after_push(agent_run_id, pr_run_without_prompt, pr_prompt_result)

            # Existing PR: mark complete with existing PR details
            complete_result = run_activity(Activities::CompleteExistingPrRunActivity,
              { agent_run_id: agent_run_id }, timeout: 60)

            # New commits invalidate prior bot feedback, so request a fresh
            # review-bot review for any still-active PR phase.
            unless complete_result[:skipped]
              if complete_result[:pr_review_phase].in?(%w[draft restarted ready escalated])
                request_review_bot_review(project_id, source_pull_request_number)
              end

              # Draft a decision record for existing PR changes (best-effort)
              draft_decision_record(agent_run_id)
            end
          else
            # Step 6: Create PR
            pr_result = run_activity(Activities::CreatePullRequestActivity,
              { agent_run_id: agent_run_id }, timeout: 60)

            unless pr_result[:skipped] || pr_result[:pull_request_url].blank?
              # Step 7: Update issue with PR link
              run_activity(Activities::UpdateIssueWithPrActivity,
                { agent_run_id: agent_run_id, pull_request_url: pr_result[:pull_request_url] }, timeout: 30)

              # Step 8: Request review-bot review on the new draft PR (best-effort)
              request_review_bot_review(project_id, pr_result[:pull_request_number])

              # Step 9: Capture screenshots for UI PRs (best-effort)
              capture_screenshots(agent_run_id)

              # Step 10: Draft a decision record (best-effort)
              draft_decision_record(agent_run_id)
            end
          end
        else
          # No changes produced by agent
          resolve_no_change_followup_review_threads(agent_run_id,
            source_pull_request_number,
            pr_run_without_prompt,
            pr_prompt_result,
            agent_result)

          if goal == "analyze_issue" && issue_id.present?
            # Analyze-issue runs assess readiness without producing code changes.
            # Mark complete and persist the "analyzed" state so the issue is
            # recognized as assessed and ready for a follow-up implementation run.
            run_activity(Activities::MarkAgentRunCompleteActivity,
              { agent_run_id: agent_run_id, reason: "no_changes" }, timeout: 30)
          elsif issue_id.present? && !source_pull_request_number
            # Issue-based run with no code changes / no PR: classify as
            # needs_input or recommend_close and post an actionable GitHub comment.
            run_activity(Activities::HandleNoOutputIssueRunActivity,
              { agent_run_id: agent_run_id,
                output_present: agent_result.fetch(:output_present, false) }, timeout: 30)
          else
            # Non-issue run or existing-PR run: mark completed
            complete_result = run_activity(Activities::MarkAgentRunCompleteActivity,
              { agent_run_id: agent_run_id, reason: "no_changes" }, timeout: 30)
          end

          # Still request a review-bot review for existing PR runs: the
          # previous run may have pushed a fix the bot has not reviewed yet.
          if source_pull_request_number && !complete_result[:skipped]
            request_review_bot_review(project_id, source_pull_request_number)
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
        # Guardrail pauses preserve the persisted AgentRun state and violation context for
        # user review, but resume! re-queues a fresh execution rather than reusing the
        # in-flight runtime artifacts from the interrupted attempt.
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

          if Temporalio::Workflow.patched("provision_mcp_servers_v1")
            begin
              run_activity(Activities::CleanupMcpServersActivity,
                { agent_run_id: agent_run_id },
                start_to_close_timeout: 120, schedule_to_close_timeout: 300,
                retry_policy: CLEANUP_RETRY_POLICY)
            rescue => e
              Temporalio::Workflow.logger.warn(
                message: "agent_execution.cleanup_mcp_servers_failed",
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

    def check_quality_gate(project_id:, issue_id:, agent_run_id:, source_pull_request_number:)
      run_activity(Activities::CheckQualityGateActivity,
        {
          project_id: project_id,
          issue_id: issue_id,
          agent_run_id: agent_run_id,
          source_pull_request_number: source_pull_request_number,
          workflow_id: current_workflow_id,
          workflow_type: "AgentExecutionWorkflow"
        }.compact,
        timeout: 30,
        retry_policy: NO_RETRY)
    end

    def quality_gate_error(gate_result)
      metrics = Array(gate_result[:breaches]).map { |breach| breach[:metric] }.join(", ")
      return "Quality gate blocked this run" if metrics.blank?

      "Quality gate blocked this run: #{metrics}"
    end

    def current_workflow_id
      Temporalio::Workflow.info.workflow_id
    rescue StandardError
      nil
    end

    # Requests a review from the project's configured review bot (Copilot,
    # Codex, etc.). The activity resolves the reviewer from project settings
    # when :reviewers is not supplied, so the workflow does not need to know
    # which bot is enabled.
    #
    # The :reviewers argument is gated behind a workflow patch so that
    # in-flight AgentExecutionWorkflow executions started before this
    # deployment — whose history recorded the old `reviewers: [copilot]`
    # payload — can replay without a non-determinism error. Histories
    # captured after the patch use the new project-resolved form.
    def request_review_bot_review(project_id, pr_number)
      return unless pr_number

      input = if Temporalio::Workflow.patched("request_review_resolve_reviewer_from_project")
        { project_id: project_id, pr_number: pr_number }
      else
        { project_id: project_id, pr_number: pr_number,
          reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] }
      end

      run_activity(Activities::RequestReviewActivity, input, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.review_bot_request_failed",
        project_id: project_id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def resolve_followup_review_threads_after_push(agent_run_id, pr_run_without_prompt, pr_prompt_result)
      if Temporalio::Workflow.patched("resolve_review_threads_with_prompt_thread_ids")
        return unless pr_run_without_prompt && pr_prompt_result[:review_thread_ids].present?

        resolve_review_threads(agent_run_id, thread_ids: pr_prompt_result[:review_thread_ids])
      else
        return unless pr_run_without_prompt

        resolve_review_threads(agent_run_id)
      end
    end

    def resolve_no_change_followup_review_threads(agent_run_id, source_pull_request_number, pr_run_without_prompt, pr_prompt_result, agent_result)
      if Temporalio::Workflow.patched("resolve_review_threads_with_prompt_thread_ids")
        return unless source_pull_request_number && pr_run_without_prompt &&
          pr_prompt_result[:includes_review_threads] &&
          pr_prompt_result[:review_thread_ids].present? &&
          agent_result[:review_threads_already_addressed]

        resolve_review_threads(agent_run_id, thread_ids: pr_prompt_result[:review_thread_ids])
      else
        return unless source_pull_request_number && pr_run_without_prompt &&
          pr_prompt_result[:includes_review_threads] &&
          agent_result[:review_threads_already_addressed]

        resolve_review_threads(agent_run_id)
      end
    end

    def resolve_review_threads(agent_run_id, thread_ids: nil)
      input = { agent_run_id: agent_run_id }
      input[:thread_ids] = thread_ids if thread_ids.present?

      run_activity(Activities::ResolveReviewThreadsActivity, input, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.resolve_threads_failed",
        agent_run_id: agent_run_id,
        error_class: e.class.name,
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

    def capture_screenshots(agent_run_id)
      run_activity(Activities::CaptureScreenshotsActivity,
        { agent_run_id: agent_run_id }, timeout: 900, retry_policy: NO_RETRY)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.capture_screenshots_failed",
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
      return false unless workflow_error

      # PostRunBookkeepingFailed means the agent completed its work but
      # post-run git operations (commit/change-detection) failed. The container
      # likely holds useful artifacts even though agent_step_succeeded is false.
      unless agent_step_succeeded
        return post_run_bookkeeping_failure?(workflow_error)
      end

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

    # Checks whether the error (or its cause chain) is a PostRunBookkeepingFailed
    # error, indicating the agent completed work but post-run git operations failed.
    def post_run_bookkeeping_failure?(error)
      current = error
      while current
        if current.is_a?(Temporalio::Error::ApplicationError)
          return true if current.type == Activities::RunAgentActivity::POST_RUN_BOOKKEEPING_ERROR_TYPE
        end
        break unless current.respond_to?(:cause)
        current = current.cause
      end
      false
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

    # Creates a cross-repo upstream/downstream issue pair:
    # 1. Create the upstream issue in the target repo
    # 2. Create the downstream issue in the current project's repo with
    #    a dependency declaration referencing the upstream issue
    #
    # If the upstream issue is created but the downstream fails, the run
    # is marked failed with the upstream issue recorded in cross_repo_issues
    # so the partial result is visible in the UI.
    def create_cross_repo_issue_pair(agent_run_id, plan)
      # Step 1: Create upstream issue in the target repo
      upstream_result = run_activity(Activities::CreateUpstreamIssueActivity,
        { agent_run_id: agent_run_id,
          target_repo: plan[:target_repo],
          title: plan[:upstream_title],
          body: plan[:upstream_body] },
        timeout: 60, retry_policy: NO_RETRY)

      # Step 2: Create downstream issue with dependency on upstream
      upstream_ref = {
        target_repo: upstream_result[:target_repo],
        issue_number: upstream_result[:issue_number],
        issue_url: upstream_result[:issue_url]
      }

      run_activity(Activities::CreateGithubIssueActivity,
        { agent_run_id: agent_run_id,
          upstream_issue: upstream_ref,
          body_override: plan[:downstream_body] },
        timeout: 120, retry_policy: NO_RETRY)
    end

    # Creates multiple issues from a decomposition plan with dependency
    # declarations wired between them. Uses a longer timeout to accommodate
    # multiple GitHub API calls (one per issue plus the parent update).
    def create_multiple_issues(agent_run_id, plan)
      run_activity(Activities::CreateMultipleIssuesActivity,
        { agent_run_id: agent_run_id,
          tasks: plan[:tasks],
          parent_issue_number: plan[:parent_issue_number] },
        timeout: 300, retry_policy: NO_RETRY)
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
