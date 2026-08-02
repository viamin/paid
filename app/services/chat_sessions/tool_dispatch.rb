# frozen_string_literal: true

module ChatSessions
  # Shared tool dispatch with structured error capture used by both the agent
  # loop (read-only tool calls) and the confirmation resolver (approved write
  # tools). Errors are normalized into tool-result hashes so the model can react
  # instead of crashing the turn.
  module ToolDispatch
    CONTAINER_WAIT_TIMEOUT = 60.seconds
    CONTAINER_WAIT_INTERVAL = 0.25
    PREPARING_WORKSPACE_MESSAGE = "Preparing workspace..."

    private

    def dispatch_tool(name:, arguments:)
      return dispatch_container_tool(name:, arguments:) if Tools::Registry.requires_container?(name)

      normalize_tool_dispatch_result(name:) do
        Tools::Registry.dispatch(
          name: name,
          arguments: arguments,
          user: chat_session.created_by,
          session: chat_session
        )
      end
    end

    def dispatch_container_tool(name:, arguments:)
      return dispatch_tool_now(name:, arguments:) if chat_session.container_ready?

      if request_lazy_container_provision!
        announce_preparing_workspace!
        return dispatch_tool_now(name:, arguments:) if provision_requested_container
      end

      if chat_session.container_pending? || chat_session.container_provisioning?
        announce_preparing_workspace!
        return dispatch_tool_now(name:, arguments:) if await_container_ready
        chat_session.reload
        return dispatch_tool_now(name:, arguments:) if chat_session.container_ready?
      end

      persist_container_capability_notice if degraded_container_capability?
      container_unavailable_result
    end

    def dispatch_tool_now(name:, arguments:)
      normalize_tool_dispatch_result(name:) do
        Tools::Registry.dispatch(
          name: name,
          arguments: arguments,
          user: chat_session.created_by,
          session: chat_session
        )
      end
    end

    def resolve_tool_confirmation(name:, decision:, pending_result:)
      normalize_tool_dispatch_result(name:) do
        Tools::Registry.resolve_confirmation(
          name: name,
          decision: decision,
          pending_result: pending_result,
          user: chat_session.created_by,
          session: chat_session
        )
      end
    end

    def normalize_tool_dispatch_result(name:)
      yield
    rescue Pundit::NotAuthorizedError => error
      { status: "error", error: "unauthorized", message: error.message }
    rescue ArgumentError => error
      { status: "error", error: "invalid_arguments", message: error.message }
    rescue StandardError => error
      log_tool_dispatch_failure(name:, error: error)
      { status: "error", error: "internal_error", message: error.message }
    end

    def log_tool_dispatch_failure(name:, error:)
      Rails.logger.error(
        message: "chat_tool_dispatch.failed",
        chat_session_id: chat_session.id,
        tool_name: name,
        error: error.message,
        error_class: error.class.name
      )
    end

    def announce_preparing_workspace!
      return if preparing_workspace_announced?

      message = chat_session.messages.create!(
        role: "assistant",
        content: PREPARING_WORKSPACE_MESSAGE,
        metadata: { "workspace_preparing_notice" => true }
      )
      on_message_persisted&.call(message)
      @preparing_workspace_announced = true
    end

    def request_lazy_container_provision!
      return false unless chat_session.inline_only? || chat_session.container_stopped?

      chat_session.request_container_provision!
    end

    def provision_requested_container
      Containers::ProvisionForChat.call(chat_session:)
      chat_session.reload
      chat_session.container_ready?
    rescue StandardError => error
      Rails.logger.warn(
        message: "chat_tool_dispatch.container_provision_failed",
        chat_session_id: chat_session.id,
        error: error.message,
        error_class: error.class.name
      )
      chat_session.reload
      false
    end

    def preparing_workspace_announced?
      @preparing_workspace_announced == true
    end

    def await_container_ready
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + container_wait_timeout

      loop do
        chat_session.reload
        return true if chat_session.container_ready?
        return false unless chat_session.container_pending? || chat_session.container_provisioning?

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if remaining <= 0

        sleep([ container_wait_interval, remaining ].min)
      end
    end

    def persist_container_capability_notice
      existing_notice = chat_session.messages.container_capability_notices.first
      return if existing_notice

      chat_session.messages.create!(
        role: "system",
        content: degraded_container_notice,
        metadata: {
          "container_capability_notice" => true,
          "container_capability" => chat_session.container_capability
        }
      )
    end

    def degraded_container_capability?
      chat_session.container_failed? || chat_session.container_stopped?
    end

    def container_unavailable_result
      {
        status: "error",
        error: "container_unavailable",
        message: Containers::CapabilityMessages.unavailable_for(chat_session.container_capability),
        container_capability: chat_session.container_capability,
        retryable: chat_session.container_pending? || chat_session.container_provisioning?
      }
    end

    def degraded_container_notice
      Containers::CapabilityMessages.notice_for(chat_session.container_capability)
    end

    def container_wait_timeout
      self.class.const_defined?(:CONTAINER_WAIT_TIMEOUT) ? self.class::CONTAINER_WAIT_TIMEOUT : CONTAINER_WAIT_TIMEOUT
    end

    def container_wait_interval
      self.class.const_defined?(:CONTAINER_WAIT_INTERVAL) ? self.class::CONTAINER_WAIT_INTERVAL : CONTAINER_WAIT_INTERVAL
    end
  end
end
