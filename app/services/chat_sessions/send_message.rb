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
    attr_reader :chat_session, :content, :on_chunk, :llm_client

    def initialize(chat_session:, content:, on_chunk: nil, llm_client: nil)
      @chat_session = chat_session
      @content = content
      @on_chunk = on_chunk
      @llm_client = llm_client
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      user_message = persist_user_message
      conversation = build_conversation
      assistant_message = execute_agent(conversation)
      update_session_activity
      assistant_message
    end

    private

    def validate!
      raise ArgumentError, "chat session must be active" unless chat_session.status == "active"
      raise ArgumentError, "content cannot be blank" if content.blank?
    end

    def persist_user_message
      chat_session.messages.create!(
        role: "user",
        content: content
      )
    end

    def build_conversation
      chat_session.messages.chronological.map do |msg|
        { role: msg.role, content: msg.content }.tap do |entry|
          entry[:tool_call_id] = msg.tool_call_id if msg.tool_call_id.present?
          entry[:tool_name] = msg.tool_name if msg.tool_name.present?
        end
      end
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
      if llm_client
        llm_client.call(conversation)
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

    def persist_assistant_response(response)
      if response[:tool_calls].present?
        handle_tool_calls(response)
      else
        create_assistant_message(response)
      end
    end

    def create_assistant_message(response)
      chat_session.messages.create!(
        role: "assistant",
        content: response[:content],
        model: response[:model],
        tokens_input: response[:tokens_input],
        tokens_output: response[:tokens_output]
      )
    end

    def handle_tool_calls(response)
      assistant_msg = create_assistant_message(response)

      response[:tool_calls].each do |tool_call|
        chat_session.messages.create!(
          role: "assistant",
          content: nil,
          tool_name: tool_call[:name],
          tool_arguments: tool_call[:arguments].to_json,
          tool_call_id: tool_call[:id]
        )

        tool_result = execute_tool(tool_call)

        chat_session.messages.create!(
          role: "tool",
          content: tool_result.to_json,
          tool_call_id: tool_call[:id],
          tool_name: tool_call[:name]
        )
      end

      assistant_msg
    end

    def execute_tool(_tool_call)
      # Placeholder for MCP tool execution via PaidMcpServer.
      # Each tool call is dispatched and its result returned.
      { status: "not_implemented" }
    end

    def update_session_activity
      chat_session.update!(
        idle_timeout_at: ChatSessions::Create::IDLE_TIMEOUT_DURATION.from_now
      )
    end
  end
end
