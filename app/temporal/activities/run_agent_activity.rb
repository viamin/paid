# frozen_string_literal: true

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    # Maps agent_type to the CLI command used inside the container.
    # Each entry is an array of command parts; the prompt is appended as the last argument.
    AGENT_COMMANDS = {
      "claude_code" => %w[claude --print --output-format=text --dangerously-skip-permissions -p]
    }.freeze

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

      command = command_prefix + [ prompt ]

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      agent_run.start!
      agent_run.log!("system", "Starting #{agent_run.agent_type} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")

      result = container_service.execute(command, timeout: agent_timeout)

      if result.success?
        # Stay in running status — the run is only marked completed after
        # push/PR activities succeed. Marking it completed here would cause
        # the container auth middleware to reject subsequent git-push requests.
        agent_run.log!("system", "Agent execution succeeded")
      else
        error_msg = "Agent exited with code #{result[:exit_code]}"
        agent_run.fail!(error: error_msg)
        raise Temporalio::Error::ApplicationError.new(
          "Agent execution failed: #{error_msg}",
          type: "AgentExecutionFailed"
        )
      end

      pre_agent_sha
    rescue Containers::Provision::TimeoutError => e
      agent_run.timeout!
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
