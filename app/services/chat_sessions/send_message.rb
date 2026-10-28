# frozen_string_literal: true

module ChatSessions
  # Core message exchange: persists the user message, then runs the agent loop
  # via `ChatSessions::AgentLoop`, streaming response chunks and persisting the
  # assistant response (including tool call/result messages). Write tools pause
  # the loop for human confirmation (RDR-028); see `ChatSessions::ResolveToolCall`.
  #
  # @example
  #   ChatSessions::SendMessage.call(
  #     chat_session: session,
  #     content: "How do I fix this bug?",
  #     on_chunk: ->(chunk) { ActionCable.server.broadcast(channel, chunk) }
  #   )
  class SendMessage
    include FallbackLoop

    attr_reader :chat_session, :actor, :content, :on_chunk, :on_message_persisted, :llm_client, :stream_message_id,
      :transport_attempt_message, :chat_turn

    MAX_CONTENT_LENGTH = 12_000

    def initialize(chat_session:, actor: chat_session.created_by, content:, on_chunk: nil, on_message_persisted: nil,
      llm_client: nil, stream_message_id: nil, chat_turn: nil)
      @chat_session = chat_session
      @actor = actor
      @content = content
      @downstream_chunk = on_chunk
      @downstream_message_persisted = on_message_persisted
      @on_chunk = method(:record_chunk)
      @on_message_persisted = method(:record_message)
      @llm_client = llm_client
      @stream_message_id = stream_message_id.presence || SecureRandom.uuid
      @chat_turn = chat_turn
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHAT-API-002
      # @spec CHAT-API-005
      validate_content!
      validate_session_state!
      check_token_limit!
      resume_session_if_needed!

      start_turn!
      persist_user_message
      persist_pending_confirmation_notice # @spec PARTIAL-CLOSEOUT-017
      assistant_message = run_with_fallbacks
      update_session_activity
      conclude_turn(assistant_message)
      assistant_message
    rescue StandardError => error
      chat_turn&.fail!(failure_classification(error))
      raise
    end

    private

    def resume_session_if_needed!
      return unless chat_session.status == "closed"

      ChatSessions::Resume.call(chat_session: chat_session)
    end

    def validate_content!
      raise ArgumentError, "content cannot be blank" if content.blank?
      raise ArgumentError, "content exceeds maximum length of #{MAX_CONTENT_LENGTH} characters" if content.length > MAX_CONTENT_LENGTH
    end

    def validate_session_state!
      raise ArgumentError, "Chat session is archived." if chat_session.status == "archived"
      return if chat_session.status == "active"
      return if resumable_closed_session?
      raise ArgumentError, "workspace chat sessions cannot be resumed" if chat_session.closed_workspace_session?

      raise ArgumentError, "chat session must be active"
    end

    def resumable_closed_session?
      chat_session.status == "closed" && chat_session.inline_only?
    end

    # @spec CHAT-API-014
    def check_token_limit!
      result = ChatSessions::CheckTokenLimit.call(chat_session: chat_session)
      # Capture the baseline so AgentLoop can guard mid-loop without re-running
      # the same SUM aggregation (see AgentLoop#token_budget).
      @token_budget = result[:remaining_tokens]
      return if result[:within_limit]

      persist_token_limit_error(result)

      raise TokenLimitExceededError.new(
        "Chat token limit reached (#{result[:limit_type]}): #{result[:limit]} tokens",
        remaining: 0,
        limit: result[:limit],
        limit_type: result[:limit_type],
        used: result[:used_tokens]
      )
    end

    # Persists a durable, visible explanation of the rejection (#3847) so it
    # survives reload instead of living only in a transient status string.
    # The user's own message is intentionally NOT persisted here — the send
    # was rejected before any work was attempted.
    def persist_token_limit_error(result)
      built = TokenLimitErrorMessage.build(
        limit_type: result[:limit_type],
        limit: result[:limit],
        used: result[:used_tokens]
      )
      message = chat_session.messages.create!(role: "system", content: built.content, metadata: built.metadata)
      on_message_persisted&.call(message)
      message
    end

    def persist_user_message
      @transport_attempt_message = existing_user_message || create_user_message
      chat_turn.update!(user_message: transport_attempt_message) unless chat_turn.user_message_id

      chat_session.generate_title_from_content!
      on_message_persisted&.call(transport_attempt_message)
      transport_attempt_message
    end

    # A restarted job retains its stream id. Reusing the original user row
    # lets its already-persisted tool results remain in the reconstructed
    # transcript instead of turning recovery into another tool dispatch.
    def existing_user_message
      return unless stream_message_id

      chat_session.messages.find_by(role: "user", metadata: { "stream_message_id" => stream_message_id })
    end

    def create_user_message
      chat_session.messages.create!(
        role: "user",
        content: content,
        metadata: { "stream_message_id" => stream_message_id }.compact
      )
    end

    # A conversational reply (e.g. "yes") is not a confirmation. When a write
    # tool still awaits explicit approval, persist a durable notice stating
    # that this message is not an approval, naming the pending action(s), and
    # confirming nothing has run yet — then let the loop continue over it.
    # The notice is a system row, so the model also sees it and cannot mistake
    # the reply for execution. Deterministic by construction: the pending row
    # is only ever settled through ChatSessions::ResolveToolCall.
    # @spec PARTIAL-CLOSEOUT-017
    def persist_pending_confirmation_notice
      pending = chat_session.messages.pending_tool_confirmations.order(:id).to_a
      return if pending.empty?

      tool_names = pending.map { |message| message.tool_name.presence || "tool" }.uniq
      message = chat_session.messages.create!(
        role: "system",
        content: pending_confirmation_notice_content(tool_names),
        metadata: {
          "pending_confirmation_notice" => true,
          "tool_names" => tool_names,
          "pending_message_ids" => pending.map(&:id)
        }
      )
      on_message_persisted&.call(message)
      message
    end

    def pending_confirmation_notice_content(tool_names)
      list = tool_names.map { |name| "`#{name}`" }.join(", ")
      "This message was not treated as approval. #{tool_names.size == 1 ? "One action" : "#{tool_names.size} actions"} " \
        "(#{list}) still await confirmation in this conversation. " \
        "Use the Approve / Deny buttons on the awaiting-confirmation card to execute or refuse it. " \
        "No action has run yet."
    end

    def update_session_activity
      chat_session.update!(
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now
      )
    end

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-005
    def start_turn!
      @chat_turn ||= chat_session.chat_turns.find_or_initialize_by(stream_message_id: stream_message_id)
      raise ArgumentError, "Chat turn has already concluded" if chat_turn.persisted? && chat_turn.terminal?

      chat_turn.assign_attributes(account: chat_session.account, initiated_by: actor, status: "streaming",
        pause_reason: nil, last_activity_at: Time.current)
      chat_turn.save!
    end

    def record_chunk(chunk)
      chat_turn&.record_activity!
      @downstream_chunk&.call(chunk)
    end

    def record_message(message, **kwargs)
      message.update!(chat_turn: chat_turn) if chat_turn && message.chat_turn_id != chat_turn.id
      chat_turn&.record_activity!
      @downstream_message_persisted&.call(message, **kwargs)
    end

    def conclude_turn(assistant_message)
      assistant_message ? chat_turn.complete! : chat_turn.pause_for_confirmation!
    end

    def failure_classification(error)
      return "client_disconnect" if error.is_a?(IOError)
      return "budget_exhausted" if error.is_a?(TokenLimitExceededError)
      return "provider_timeout" if error.is_a?(Timeout::Error)
      return "rate_limited" if error.is_a?(AgentHarness::RateLimitError)
      return "provider_error" if error.is_a?(AgentHarness::Error)

      "application_error"
    end

    # Reuse the pre-loop budget baseline so the mid-loop guard does not issue a
    # second SUM query per turn. Only forward when a limit is configured; a nil
    # baseline means "unlimited" and AgentLoop re-derives nil cheaply.
    def extra_agent_loop_kwargs
      @token_budget ? { token_budget: @token_budget } : {}
    end
  end
end
