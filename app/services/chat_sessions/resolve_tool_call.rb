# frozen_string_literal: true

module ChatSessions
  # Resolves a pending write-tool confirmation (RDR-028). On approval the tool is
  # dispatched with +confirmed: true+ (Pundit re-checked at execution time), the
  # result is persisted, and the agent loop resumes. On denial a structured
  # +{ status: "denied" }+ result is fed back so the model can adjust. Both
  # outcomes persist, so the confirmation survives reconnects and idle-reaper
  # boundaries.
  class ResolveToolCall
    include ToolDispatch

    DECISIONS = %i[approve deny].freeze
    DENIED_RESULT = { status: "denied", message: "The requested action was not approved" }.freeze

    attr_reader :chat_session, :tool_call_message, :decision, :llm_client,
      :on_chunk, :on_message_persisted, :on_tool_call_resolved, :stream_message_id

    def initialize(chat_session:, tool_call_message:, decision:, llm_client:, on_chunk: nil,
      on_message_persisted: nil, on_tool_call_resolved: nil, stream_message_id: nil)
      @chat_session = chat_session
      @tool_call_message = tool_call_message
      @decision = decision.to_sym
      @llm_client = llm_client
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @on_tool_call_resolved = on_tool_call_resolved
      @stream_message_id = stream_message_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      resolve_pending_tool_call!
      update_session_activity
      resume_loop
    end

    private

    def validate!
      raise ArgumentError, "Tool call is not awaiting confirmation" unless tool_call_message.pending_confirmation?
      raise ArgumentError, "decision must be approve or deny" unless DECISIONS.include?(decision)
    end

    def resolve_pending_tool_call!
      approve? ? approve_tool_call! : deny_tool_call!
      mark_resolved!
    end

    def approve_tool_call!
      result = dispatch_tool(name: tool_call_message.tool_name, arguments: confirmed_arguments)
      persist_tool_result(result)
    end

    def deny_tool_call!
      persist_tool_result(DENIED_RESULT)
    end

    def mark_resolved!
      tool_call_message.update!(tool_status: decision_status)
      on_tool_call_resolved&.call(tool_call_message)
    end

    def decision_status
      approve? ? "approved" : "denied"
    end

    def approve?
      decision == :approve
    end

    # The model never sees the +confirmed+ flag (it is stripped from advertised
    # schemas). Approval injects it here so the write tool's guard passes — the
    # human approver, not the model, authorizes the mutation.
    def confirmed_arguments
      (tool_call_message.tool_arguments || {}).merge("confirmed" => true)
    end

    def persist_tool_result(result)
      message = chat_session.messages.create!(
        role: "tool",
        content: result.to_json,
        tool_result: result,
        tool_call_id: tool_call_message.tool_call_id,
        tool_name: tool_call_message.tool_name
      )

      on_message_persisted&.call(message)
      message
    end

    def resume_loop
      ChatSessions::AgentLoop.new(
        chat_session: chat_session,
        llm_client: llm_client,
        on_chunk: on_chunk,
        on_message_persisted: on_message_persisted,
        stream_message_id: stream_message_id
      ).run
    end

    def update_session_activity
      chat_session.update!(
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now
      )
    end
  end
end
