# frozen_string_literal: true

module ChatSessions
  # Shared tool dispatch with structured error capture used by both the agent
  # loop (read-only tool calls) and the confirmation resolver (approved write
  # tools). Errors are normalized into tool-result hashes so the model can react
  # instead of crashing the turn.
  module ToolDispatch
    private

    def dispatch_tool(name:, arguments:)
      Tools::Registry.dispatch(
        name: name,
        arguments: arguments,
        user: chat_session.created_by,
        session: chat_session
      )
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
  end
end
