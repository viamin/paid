# frozen_string_literal: true

require "docker-api"

module Containers
  # Manages the lifecycle of a chat session's Docker container.
  #
  # Handles command execution, idle timeout extension, health checks,
  # and cleanup for interactive workspace chat sessions.
  #
  # @example Execute an agent command
  #   manager = Containers::ChatSessionManager.new(chat_session)
  #   result = manager.execute_agent_command(prompt: "Fix the tests")
  #
  # @example Resume a session
  #   result = manager.execute_agent_command(
  #     prompt: "Continue with the refactor",
  #     session_id: "previous-session-id"
  #   )
  class ChatSessionManager
    Result = Containers::Provision::Result

    class Error < StandardError; end
    class ContainerNotRunning < Error; end
    class ExecutionError < Error; end

    EXECUTE_TIMEOUT = 1.hour.to_i
    MAX_SESSION_DURATION = 4.hours

    attr_reader :chat_session

    def initialize(chat_session)
      @chat_session = chat_session
    end

    # Executes an agent CLI command inside the container.
    #
    # Delegates command building to agent-harness via Providers::HarnessExecutionPlan
    # so the correct CLI is invoked for whatever provider the chat session uses
    # (Claude, Codex, Gemini, etc.) without hard-coding provider-specific commands.
    #
    # @param prompt [String] The prompt/task for the agent
    # @param session_id [String, nil] Session ID for resuming a previous session
    # @return [Result] with stdout, stderr, exit_code, and extracted session_id
    def execute_agent_command(prompt:, session_id: nil)
      ensure_container_running!

      command = build_agent_command(prompt: prompt, session_id: session_id)
      stdout_buffer = []
      stderr_buffer = []

      exec_result = container.exec(
        [ "sh", "-c", command ],
        wait: EXECUTE_TIMEOUT
      ) do |stream_type, chunk|
        case stream_type
        when :stdout then stdout_buffer << chunk
        when :stderr then stderr_buffer << chunk
        end
      end

      exit_code = exec_result.is_a?(Array) ? exec_result[2] : 0
      stdout = stdout_buffer.join
      stderr = stderr_buffer.join

      extend_idle_timeout!

      log("execute.complete", exit_code: exit_code)

      if exit_code == 0
        Result.success(
          stdout: stdout,
          stderr: stderr,
          exit_code: exit_code,
          session_id: extract_session_id(stdout) || session_id
        )
      else
        Result.failure(
          error: "Agent command exited with code #{exit_code}",
          stdout: stdout,
          stderr: stderr,
          exit_code: exit_code,
          session_id: session_id
        )
      end
    rescue Docker::Error::DockerError => e
      log("execute.failed", error: e.message)
      raise ExecutionError, "Docker exec error: #{e.message}"
    end

    # Resets the idle timeout on the chat session, clamped to MAX_SESSION_DURATION
    # from the session's creation time to prevent unbounded container lifetimes.
    #
    # @param duration [ActiveSupport::Duration] Timeout duration (default: 30 minutes)
    def extend_idle_timeout!(duration: 30.minutes)
      max_timeout_at = chat_session.created_at + MAX_SESSION_DURATION
      new_timeout_at = [ duration.from_now, max_timeout_at ].min
      chat_session.update!(idle_timeout_at: new_timeout_at)
    end

    # Checks if the container is running and responsive.
    #
    # @return [Hash] { healthy: true/false, message: "..." }
    def health_check
      unless chat_session.container_id.present?
        return { healthy: false, message: "No container assigned" }
      end

      container.refresh!
      running = container.info.dig("State", "Running") == true

      if running
        { healthy: true, message: "Container is running" }
      else
        { healthy: false, message: "Container is not running" }
      end
    rescue Docker::Error::NotFoundError
      { healthy: false, message: "Container not found" }
    rescue Docker::Error::DockerError => e
      { healthy: false, message: "Docker error: #{e.message}" }
    end

    # Stops and removes the container and workspace volume.
    # Keeps the state volume if preserve_state is true for session resume.
    #
    # @param preserve_state [Boolean] Whether to keep the state volume
    def cleanup!(preserve_state: false)
      log("cleanup.start")

      if chat_session.container_id.present?
        stop_and_remove_container
      end

      remove_workspace_volume

      unless preserve_state
        remove_state_volume
      end

      chat_session.update!(container_id: nil, workspace_volume: nil)
      @container = nil
      log("cleanup.success")
    end

    private

    def container
      @container ||= Docker::Container.get(chat_session.container_id)
    end

    def ensure_container_running!
      raise ContainerNotRunning, "No container assigned" unless chat_session.container_id.present?

      container.refresh!
      running = container.info.dig("State", "Running") == true
      raise ContainerNotRunning, "Container is not running" unless running
    rescue Docker::Error::NotFoundError
      raise ContainerNotRunning, "Container not found"
    end

    # Builds the agent CLI command using agent-harness execution plans.
    # Falls back to the provider key from the chat session's provider, or
    # defaults to "claude" when no provider is configured.
    def build_agent_command(prompt:, session_id: nil)
      plan = Providers::HarnessExecutionPlan.for_provider_key(
        provider_key: effective_provider_key,
        prompt: prompt,
        options: session_id.present? ? { session_id: session_id } : {}
      )
      Shellwords.join(plan.command)
    end

    def effective_provider_key
      chat_session.provider&.provider_key || "claude"
    end

    def extract_session_id(output)
      match = output.match(/session_id[=: ]+([a-f0-9-]+)/i)
      match&.captures&.first
    end

    def stop_and_remove_container
      docker_container = Docker::Container.get(chat_session.container_id)
      begin
        docker_container.stop(timeout: 10)
      rescue Docker::Error::NotFoundError
        return
      rescue Docker::Error::DockerError
        # Container may have already stopped
      end

      begin
        docker_container.delete(force: true, v: true)
      rescue Docker::Error::DockerError
        # Container may already be gone
      end
    rescue Docker::Error::NotFoundError
      # Container already removed
    end

    def remove_workspace_volume
      volume_name = chat_session.workspace_volume || "paid-chat-workspace-#{chat_session.id}"
      Docker::Volume.get(volume_name).remove
    rescue Docker::Error::DockerError
      # Volume may already be removed
    end

    def remove_state_volume
      volume_name = "paid-chat-state-#{chat_session.id}"
      Docker::Volume.get(volume_name).remove
    rescue Docker::Error::DockerError
      # Volume may already be removed
    end

    def log(action, **metadata)
      Rails.logger.info(
        message: "container_manager.chat.#{action}",
        chat_session_id: chat_session.id,
        project_id: chat_session.project_id,
        **metadata
      )
    end
  end
end
