# frozen_string_literal: true

module ChatSessions
  # Core message exchange: persists the user message, builds conversation
  # history, executes the agent via agent-harness, streams response chunks,
  # and persists the assistant response (including tool call/result messages).
  #
  # @example
  #   ChatSessions::SendMessage.call(
  #     chat_session: session,
  #     content: "How do I fix this bug?",
  #     on_chunk: ->(chunk) { ActionCable.server.broadcast(channel, chunk) }
  #   )
  class SendMessage
    attr_reader :chat_session, :content, :on_chunk, :on_message_persisted, :llm_client, :stream_message_id

    def initialize(chat_session:, content:, on_chunk: nil, on_message_persisted: nil, llm_client: nil, stream_message_id: nil)
      @chat_session = chat_session
      @content = content
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @llm_client = llm_client
      @stream_message_id = stream_message_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      check_token_limit!

      persist_user_message
      conversation = build_conversation
      assistant_message = execute_agent(conversation)
      track_token_usage(assistant_message)
      update_session_activity
      assistant_message
    end

    private

    MAX_CONTENT_LENGTH = 12_000
    MAX_CONVERSATION_MESSAGES = 200

    def validate!
      raise ArgumentError, "chat session must be active" unless chat_session.status == "active"
      raise ArgumentError, "content cannot be blank" if content.blank?
      raise ArgumentError, "content exceeds maximum length of #{MAX_CONTENT_LENGTH} characters" if content.length > MAX_CONTENT_LENGTH
    end

    def check_token_limit!
      result = ChatSessions::CheckTokenLimit.call(chat_session: chat_session)
      return if result[:within_limit]

      raise TokenLimitExceededError.new(
        "Chat token limit reached (#{result[:limit_type]}): #{result[:limit]} tokens",
        remaining: 0,
        limit: result[:limit],
        limit_type: result[:limit_type]
      )
    end

    def persist_user_message
      message = chat_session.messages.create!(
        role: "user",
        content: content
      )

      chat_session.generate_title_from_content!
      on_message_persisted&.call(message)
      message
    end

    # Cap conversation history to avoid unbounded memory growth and
    # exceeding the LLM context window in long-running sessions.

    def build_conversation
      messages = chat_session.messages.chronological
      messages = messages.last(MAX_CONVERSATION_MESSAGES)

      messages.map do |msg|
        { role: msg.role, content: conversation_content_for(msg) }.tap do |entry|
          if assistant_tool_call_message?(msg)
            entry[:tool_calls] = [
              {
                id: msg.tool_call_id,
                name: msg.tool_name,
                arguments: msg.tool_arguments
              }
            ]
          else
            entry[:tool_call_id] = msg.tool_call_id if msg.tool_call_id.present?
            entry[:tool_name] = msg.tool_name if msg.tool_name.present?
          end
        end
      end
    end

    def assistant_tool_call_message?(message)
      message.role == "assistant" &&
        message.content.blank? &&
        message.tool_call_id.present? &&
        message.tool_name.present? &&
        message.tool_arguments.present?
    end

    def conversation_content_for(message)
      return message.tool_result if message.role == "tool" && message.tool_result.present?
      return message.content if message.content.present?
      return message.tool_result if message.tool_result.present?

      nil
    end

    def execute_agent(conversation)
      case chat_session.mode
      when "api"
        execute_api_mode(conversation)
      when "workspace"
        execute_workspace_mode(conversation)
      end
    end

    def execute_api_mode(conversation)
      response = call_llm(conversation)
      persist_assistant_response(response)
    end

    def execute_workspace_mode(conversation)
      response = call_llm(conversation)
      persist_assistant_response(response)
    end

    def call_llm(conversation)
      chunk_streamed = false
      chunk_callback = lambda do |chunk|
        next if chunk.blank?

        chunk_streamed = true
        on_chunk&.call(chunk)
      end

      if llm_client
        invoke_llm_client(conversation, chunk_callback).tap do |response|
          replay_response_content(response, chunk_callback) unless chunk_streamed
        end
      else
        # Delegate to agent-harness for LLM interaction.
        # Returns a response hash with :content, :tool_calls, :tokens_input, :tokens_output.
        #
        # This is a stub for the agent-harness chat transport integration
        # (depends on agent-harness AH-1, AH-2, AH-3).
        # In production, this calls provider.send_chat_message(conversation:, stream:).
        raise NotImplementedError, "agent-harness chat transport not yet integrated"
      end
    end

    def invoke_llm_client(conversation, chunk_callback)
      call_llm_client(
        conversation,
        include_tools: llm_client_supports_tools?,
        include_on_chunk: on_chunk && llm_client_supports_chunk_callback?,
        chunk_callback: chunk_callback
      )
    rescue ArgumentError => error
      raise error unless unsupported_llm_client_keyword?(error)

      call_llm_client(
        conversation,
        include_tools: false,
        include_on_chunk: on_chunk && llm_client_supports_chunk_callback? && !unsupported_on_chunk_callback?(error),
        chunk_callback: chunk_callback
      )
    end

    def replay_response_content(response, chunk_callback)
      response[:content].to_s.scan(/\S+\s*|\s+/).each do |chunk|
        chunk_callback.call(chunk)
      end
    end

    def unsupported_on_chunk_callback?(error)
      error.message.include?("unknown keyword: :on_chunk") || error.message.match?(/wrong number of arguments/)
    end

    def unsupported_tools_keyword?(error)
      error.message.include?("unknown keyword: :tools") || error.message.match?(/wrong number of arguments/)
    end

    def unsupported_llm_client_keyword?(error)
      unsupported_on_chunk_callback?(error) || unsupported_tools_keyword?(error)
    end

    def llm_client_supports_chunk_callback?
      llm_client_supports_keyword?(:on_chunk)
    end

    def llm_client_supports_tools?
      llm_client_supports_keyword?(:tools)
    end

    def llm_client_supports_keyword?(keyword)
      llm_client.method(:call).parameters.any? do |kind, name|
        (kind == :keyrest) || ([ :key, :keyreq ].include?(kind) && name == keyword)
      end
    end

    def call_llm_client(conversation, include_tools:, include_on_chunk:, chunk_callback:)
      kwargs = {}
      kwargs[:tools] = tool_definitions if include_tools
      kwargs[:on_chunk] = chunk_callback if include_on_chunk

      return llm_client.call(conversation, **kwargs) if kwargs.any?

      llm_client.call(conversation)
    end

    def tool_definitions
      @tool_definitions ||= PaidMcpServer.new(session: chat_session, user: chat_session.created_by).tool_definitions
    end

    def persist_assistant_response(response)
      if response[:tool_calls].present?
        handle_tool_calls(response)
      else
        create_assistant_message(response)
      end
    end

    def create_assistant_message(response)
      message = chat_session.messages.create!(
        role: "assistant",
        content: response[:content],
        model: response[:model],
        tokens_input: response[:tokens_input],
        tokens_output: response[:tokens_output]
      )

      on_message_persisted&.call(message, stream_message_id: stream_message_id)
      message
    end

    def handle_tool_calls(response)
      assistant_msg = create_assistant_message(response)

      response[:tool_calls].each do |tool_call|
        tool_call_message = chat_session.messages.create!(
          role: "assistant",
          content: nil,
          tool_name: tool_call[:name],
          tool_arguments: tool_call[:arguments],
          tool_call_id: tool_call[:id]
        )
        on_message_persisted&.call(tool_call_message)

        tool_result = execute_tool(tool_call)

        tool_result_message = chat_session.messages.create!(
          role: "tool",
          content: tool_result.to_json,
          tool_result: tool_result,
          tool_call_id: tool_call[:id],
          tool_name: tool_call[:name]
        )
        on_message_persisted&.call(tool_result_message)
      end

      assistant_msg
    end

    def execute_tool(_tool_call)
      # Placeholder for MCP tool execution via PaidMcpServer.
      # Each tool call is dispatched and its result returned.
      { status: "not_implemented" }
    end

    def track_token_usage(assistant_message)
      return unless assistant_message.tokens_input.to_i.positive? || assistant_message.tokens_output.to_i.positive?

      input_tokens = assistant_message.tokens_input.to_i
      output_tokens = assistant_message.tokens_output.to_i
      cost_cents = TokenUsageTracker.calculate_cost(input_tokens, output_tokens, llm_model: assistant_message.model)

      # Chat message delivery can run on ActionController::Live request threads,
      # where per-connection RLS state is not always reliably preserved for
      # association-based internal telemetry writes. The chat session itself was
      # already policy-scoped before execution, so record usage with system
      # access to avoid dropping successful responses on an internal audit write.
      TenantContext.with_system_access do
        TokenUsage.create!(
          chat_session_id: chat_session.id,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_cents: cost_cents,
          llm_model: assistant_message.model,
          request_type: "chat_message"
        )
      end

      Projects::StatsSummary.bust_cache!(chat_session.project_id) if chat_session.project_id
    end

    def update_session_activity
      chat_session.update!(
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now
      )
    end
  end
end
