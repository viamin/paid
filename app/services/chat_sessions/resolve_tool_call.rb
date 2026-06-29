# frozen_string_literal: true

module ChatSessions
  # Resolves a pending write-tool confirmation (RDR-028). On approval the tool is
  # dispatched with +confirmed: true+ (Pundit re-checked at execution time), the
  # result is persisted, and the agent loop resumes. On denial a structured
  # +{ status: "denied" }+ result is fed back so the model can adjust. Both
  # outcomes persist, so the confirmation survives reconnects and idle-reaper
  # boundaries.
  #
  # When several write tools are pending at once (a multi-tool batch), each is
  # resolved independently; the agent loop only resumes once the *last* pending
  # confirmation is settled, so the rebuilt conversation never exposes an
  # unanswered tool call to the model.
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
      validate_decision!
      claim_resolution!
      update_session_activity

      if post_dispatch_confirmation?
        resolve_post_dispatch_confirmation!
      else
        resolve_pending_tool_call!
        resume_loop_unless_other_pending
      end
    end

    private

    def validate_decision!
      raise ArgumentError, "decision must be approve or deny" unless DECISIONS.include?(decision)
    end

    # Atomically transition this tool call from +pending+ to its decision status
    # via a database compare-and-swap, so only one concurrent resolver wins a
    # race (double-click, two browser tabs, channel + HTTP endpoint). The claim
    # happens *before* the tool is dispatched, so the losing caller raises
    # before producing any side effects — a write tool can never run twice for a
    # single request.
    def claim_resolution!
      rows = chat_session.messages
        .where(id: tool_call_message.id, tool_status: "pending")
        .update_all(tool_status: decision_status)

      raise ArgumentError, "Tool call is not awaiting confirmation" if rows.zero?

      tool_call_message.reload
      on_tool_call_resolved&.call(tool_call_message)
    end

    def resolve_pending_tool_call!
      approve? ? approve_tool_call! : deny_tool_call!
    end

    # Post-dispatch tools run their mutating second phase (e.g. activating or
    # discarding a draft Change Intent Record) during confirmation resolution.
    # `claim_resolution!` has already flipped the row out of `pending` by the
    # time this runs, so a failed second phase must roll the status back to
    # `pending` — otherwise the draft is stranded behind an approved/denied row
    # that this service (which only accepts pending rows) can never touch again.
    # The rolled-back confirmation is re-broadcast so the human can retry it.
    def resolve_post_dispatch_confirmation!
      result = resolve_post_dispatch_confirmation
      return rollback_to_pending(error_result: result) if error_result?(result)

      persist_tool_result(result)
      resume_loop_unless_other_pending
    end

    def approve_tool_call!
      result = dispatch_tool(name: tool_call_message.tool_name, arguments: confirmed_arguments)
      persist_tool_result(result)
    end

    def deny_tool_call!
      persist_tool_result(DENIED_RESULT)
    end

    def rollback_to_pending(error_result:)
      chat_session.messages
        .where(id: tool_call_message.id, tool_status: decision_status)
        .update_all(tool_status: "pending")
      tool_call_message.reload
      on_tool_call_resolved&.call(tool_call_message)
      log_rolled_back_confirmation(error_result:)
    end

    def error_result?(result)
      return false unless result.is_a?(Hash)

      result[:status] == "error" || result["status"] == "error"
    end

    def log_rolled_back_confirmation(error_result:)
      Rails.logger.warn(
        message: "chat_tool_confirmation.rolled_back",
        chat_session_id: chat_session.id,
        tool_name: tool_call_message.tool_name,
        tool_error: error_result[:error] || error_result["error"],
        error_message: error_result[:message] || error_result["message"]
      )
    end

    def decision_status
      approve? ? "approved" : "denied"
    end

    def approve?
      decision == :approve
    end

    def post_dispatch_confirmation?
      Tools::Registry.post_dispatch_confirmation?(tool_call_message.tool_name)
    end

    # The model never sees the +confirmed+ flag (it is stripped from advertised
    # schemas). Approval injects it here so the write tool's guard passes — the
    # human approver, not the model, authorizes the mutation.
    def confirmed_arguments
      (tool_call_message.tool_arguments || {}).merge("confirmed" => true)
    end

    def resolve_post_dispatch_confirmation
      resolve_tool_confirmation(
        name: tool_call_message.tool_name,
        decision: decision,
        pending_result: tool_call_message.tool_result || {}
      )
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

    def resume_loop_unless_other_pending
      return nil if other_pending_confirmations?

      resume_loop
    end

    def other_pending_confirmations?
      chat_session.messages.pending_tool_confirmations.exists?
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
