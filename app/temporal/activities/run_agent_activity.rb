# frozen_string_literal: true

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    # Maps agent_type to the CLI command used inside the container.
    # Each entry is an array of command parts; the prompt is appended as the last argument.
    AGENT_COMMANDS = {
      "claude_code" => %w[claude --print --output-format=text --dangerously-skip-permissions -p]
    }.freeze

    # Issue creation should complete quickly — use a shorter timeout than full PR runs.
    ISSUE_GOAL_TIMEOUT = 600        # 10 minutes wall clock
    ISSUE_GOAL_IDLE_TIMEOUT = 120   # 2 minutes without output = stuck

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      prompt = agent_run.effective_prompt
      raise Temporalio::Error::ApplicationError.new("No prompt available for agent run", type: "MissingPrompt") unless prompt

      pre_agent_sha = run_agent_in_container(agent_run, prompt)

      commit_uncommitted_changes(agent_run)

      has_changes = check_for_changes(agent_run, pre_agent_sha)

      {
        agent_run_id: agent_run_id,
        success: true,
        has_changes: has_changes
      }
    end

    private

    # Runs the agent CLI inside the container and returns the pre-agent HEAD SHA.
    #
    # Captures HEAD before the agent executes so callers can detect whether
    # the agent made any new changes (vs. commits from prior runs).
    #
    # @return [String, nil] the HEAD SHA before the agent ran, or nil on capture failure
    def run_agent_in_container(agent_run, prompt)
      container_service = reconnect_container(agent_run)

      command_prefix = AGENT_COMMANDS[agent_run.agent_type]
      unless command_prefix
        raise Temporalio::Error::ApplicationError.new(
          "Unsupported agent type for container execution: #{agent_run.agent_type}",
          type: "UnsupportedAgentType"
        )
      end

      prompt = augment_prompt_for_issue_goal(agent_run, prompt)

      command = command_prefix + [ prompt ]

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      agent_run.start!
      agent_run.log!("system", "Starting #{agent_run.agent_type} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")

      effective_timeout = agent_run.create_issue_goal? ? ISSUE_GOAL_TIMEOUT : agent_timeout
      effective_idle_timeout = agent_run.create_issue_goal? ? ISSUE_GOAL_IDLE_TIMEOUT : nil

      result = container_service.execute(command, timeout: effective_timeout, idle_timeout: effective_idle_timeout)

      if result.success?
        # Stay in running status — the run is only marked completed after
        # push/PR activities succeed. Marking it completed here would cause
        # the container auth middleware to reject subsequent git-push requests.
        agent_run.log!("system", "Agent execution succeeded")
      else
        output = (result[:stderr].presence || result[:stdout]).to_s.strip.truncate(500)
        error_msg = "Agent exited with code #{result[:exit_code]}: #{output}"
        agent_run.fail!(error: error_msg)
        raise Temporalio::Error::ApplicationError.new(
          "Agent execution failed: #{error_msg}",
          type: "AgentExecutionFailed"
        )
      end

      pre_agent_sha
    rescue Containers::Provision::TimeoutError => e
      timeout_type = case e
      when Containers::Provision::StartupTimeoutError then "startup"
      when Containers::Provision::IdleTimeoutError then "idle"
      else "wall_clock"
      end
      agent_run.timeout!(error: "#{timeout_type}_timeout: #{e.message}")
      ProcessRunQueueJob.perform_later
      raise Temporalio::Error::ApplicationError.new(e.message, type: "AgentTimeout")
    end

    def capture_head_sha(container_service, agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )
      git_ops.head_sha
    rescue => e
      logger.warn(
        message: "agent_execution.capture_head_sha_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      nil
    end

    # Commits any uncommitted changes the agent left behind.
    # Agents may edit files without running git add/commit;
    # this ensures those edits are captured before push.
    def commit_uncommitted_changes(agent_run)
      return unless agent_run.container_id.present?

      container_service = reconnect_container(agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      if git_ops.commit_uncommitted_changes
        agent_run.log!("system", "Auto-committed uncommitted agent changes")
      end
    rescue => e
      logger.warn(
        message: "agent_execution.commit_uncommitted_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end

    def check_for_changes(agent_run, pre_agent_sha)
      return false unless agent_run.container_id.present?

      container_service = reconnect_container(agent_run)

      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      if pre_agent_sha.present?
        git_ops.has_changes_since?(pre_agent_sha)
      else
        git_ops.has_changes?
      end
    rescue => e
      logger.warn(
        message: "agent_execution.check_changes_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      false
    end

    def augment_prompt_for_issue_goal(agent_run, prompt)
      return prompt unless agent_run.create_issue_goal?

      # full_name is "owner/repo" from our DB (set during GitHub import).
      # Validate format to prevent injection in the shell command example.
      repo = agent_run.project.full_name
      unless repo.match?(%r{\A[A-Za-z0-9\-_.]+/[A-Za-z0-9\-_.]+\z})
        raise Temporalio::Error::ApplicationError.new(
          "Invalid repository name format: #{repo.inspect}",
          type: "InvalidRepoName"
        )
      end
      <<~AUGMENTED
        #{prompt}

        ---
        IMPORTANT: Your goal is to CREATE A GITHUB ISSUE, not to write code or create a PR.

        You have access to the GitHub API via a proxy. Use curl to create the issue:

        ```bash
        curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/issues" \\
          -H "Content-Type: application/json" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN" \\
          -d '{"title": "Issue title", "body": "Issue description", "labels": []}'
        ```

        Available endpoints:
        - GET  $GITHUB_API_URL/repos/#{repo}/issues — list issues
        - GET  $GITHUB_API_URL/repos/#{repo}/issues/{number} — get issue
        - POST $GITHUB_API_URL/repos/#{repo}/issues — create issue
        - PATCH $GITHUB_API_URL/repos/#{repo}/issues/{number} — update issue
        - POST $GITHUB_API_URL/repos/#{repo}/issues/{number}/comments — add comment
        - POST $GITHUB_API_URL/repos/#{repo}/issues/{number}/labels — add labels

        Do NOT push code or create a pull request. Only create the GitHub issue.
      AUGMENTED
    end

    def reconnect_container(agent_run)
      raise Temporalio::Error::ApplicationError.new(
        "No container provisioned for agent run #{agent_run.id}",
        type: "ContainerNotProvisioned"
      ) if agent_run.container_id.blank?

      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end

    def agent_timeout
      Rails.application.config.x.agent_timeout
    end
  end
end
