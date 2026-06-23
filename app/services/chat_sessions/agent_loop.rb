# frozen_string_literal: true

module ChatSessions
  # Runs the chat agent loop against persisted conversation history: calls the
  # LLM, executes read-only tool calls inline, and surfaces write tools for
  # human confirmation (RDR-028). The loop pauses (returns +nil+) the first time
  # the model requests a write tool, leaving a pending confirmation in place for
  # `ChatSessions::ResolveToolCall` to resume after approval.
  #
  # Both `ChatSessions::SendMessage` (initial turn) and
  # `ChatSessions::ResolveToolCall` (after approve/deny) delegate to this class.
  class AgentLoop
    include ToolDispatch

    MAX_TOOL_ITERATIONS = 8
    MAX_CONVERSATION_MESSAGES = 200
    TOOL_ITERATION_LIMIT_MESSAGE = "I hit the maximum number of tool iterations for this turn. Please try again with a narrower request."

    attr_reader :chat_session, :llm_client, :on_chunk, :on_message_persisted, :stream_message_id

    def initialize(chat_session:, llm_client:, on_chunk: nil, on_message_persisted: nil, stream_message_id: nil)
      @chat_session = chat_session
      @llm_client = llm_client
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @stream_message_id = stream_message_id
    end

    # @return [ChatMessage, nil] the final assistant message, or +nil+ when the
    #   loop paused to await confirmation for a write tool.
    def run
      conversation = build_conversation
      final_assistant_message = run_loop(conversation)
      finalize_token_usage(final_assistant_message) if final_assistant_message
      final_assistant_message
    end

    private

    def run_loop(conversation)
      aggregate_tokens = { input: 0, output: 0 }
      final_assistant_message = nil
      last_response_model = nil

      MAX_TOOL_ITERATIONS.times do |iteration|
        response = call_llm(conversation)
        aggregate_tokens[:input] += response[:tokens_input].to_i
        aggregate_tokens[:output] += response[:tokens_output].to_i
        last_response_model = response[:model]

        final_assistant_message = create_assistant_message(response) if response[:content].present?
        break if response[:tool_calls].blank?

        conversation << {
          role: "assistant",
          content: response[:content],
          tool_calls: response[:tool_calls]
        }

        if pending_write_tool?(response[:tool_calls])
          return pause_for_confirmation(response[:tool_calls], aggregate_tokens:, model: last_response_model)
        end

        response[:tool_calls].each do |tool_call|
          persist_tool_call_message(tool_call)

          tool_result = dispatch_tool(name: tool_call[:name], arguments: parse_tool_arguments(tool_call))
          persist_tool_result_message(tool_call, tool_result)

          conversation << {
            role: "tool",
            content: tool_result,
            tool_call_id: tool_call[:id],
            tool_name: tool_call[:name]
          }
        end

        next unless iteration == (MAX_TOOL_ITERATIONS - 1)

        final_assistant_message = create_assistant_message(
          content: TOOL_ITERATION_LIMIT_MESSAGE,
          model: last_response_model
        )
      end

      stamp_aggregate_tokens(final_assistant_message, aggregate_tokens, last_response_model)
    end

    # When the model requests a write tool, persist the request as a pending
    # confirmation and stop the loop so a human can approve or deny it.
    def pause_for_confirmation(tool_calls, aggregate_tokens:, model:)
      pending_tool_call = tool_calls.find { |tool_call| Tools::Registry.write_tool?(tool_call[:name]) }
      persist_pending_tool_call_message(pending_tool_call)
      stamp_aggregate_tokens(nil, aggregate_tokens, model)
      nil
    end

    def pending_write_tool?(tool_calls)
      tool_calls.any? { |tool_call| Tools::Registry.write_tool?(tool_call[:name]) }
    end

    def build_conversation
      messages = chat_session.messages.chronological
      messages = messages.last(MAX_CONVERSATION_MESSAGES)

      messages.each_with_object([]) do |msg, conversation|
        if assistant_tool_call_message?(msg)
          append_assistant_tool_call_entry(conversation, msg)
        else
          conversation << build_conversation_entry(msg)
        end
      end
    end

    def assistant_tool_call_message?(message)
      message.role == "assistant" &&
        message.content.blank? &&
        message.tool_call_id.present? &&
        message.tool_name.present?
    end

    def conversation_content_for(message)
      return message.tool_result if message.role == "tool" && message.tool_result.present?
      return message.content if message.content.present?
      return message.tool_result if message.tool_result.present?

      nil
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
      @tool_definitions ||= Tools::Registry.chat_definitions_for(user: chat_session.created_by)
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

    def persist_tool_call_message(tool_call, status: nil)
      tool_call_message = chat_session.messages.create!(
        role: "assistant",
        content: nil,
        tool_name: tool_call[:name],
        tool_arguments: parse_tool_arguments(tool_call),
        tool_call_id: tool_call[:id],
        tool_status: status
      )

      on_message_persisted&.call(tool_call_message)
      tool_call_message
    end

    def persist_pending_tool_call_message(tool_call)
      persist_tool_call_message(tool_call, status: "pending")
    end

    def persist_tool_result_message(tool_call, tool_result)
      tool_result_message = chat_session.messages.create!(
        role: "tool",
        content: tool_result.to_json,
        tool_result: tool_result,
        tool_call_id: tool_call[:id],
        tool_name: tool_call[:name]
      )

      on_message_persisted&.call(tool_result_message)
      tool_result_message
    end

    def parse_tool_arguments(tool_call)
      arguments = tool_call[:arguments]
      return {} if arguments.blank?
      return arguments if arguments.is_a?(Hash)

      JSON.parse(arguments)
    rescue JSON::ParserError
      {}
    end

    def finalize_token_usage(assistant_message)
      return unless assistant_message.tokens_input.to_i.positive? || assistant_message.tokens_output.to_i.positive?

      input_tokens = assistant_message.tokens_input.to_i
      output_tokens = assistant_message.tokens_output.to_i
      cost_cents = TokenUsageTracker.calculate_cost(input_tokens, output_tokens, llm_model: assistant_message.model)

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

    def build_conversation_entry(message)
      { role: message.role, content: conversation_content_for(message) }.tap do |entry|
        entry[:tool_call_id] = message.tool_call_id if message.tool_call_id.present?
        entry[:tool_name] = message.tool_name if message.tool_name.present?
      end
    end

    def append_assistant_tool_call_entry(conversation, message)
      tool_call = {
        id: message.tool_call_id,
        name: message.tool_name,
        arguments: message.tool_arguments
      }

      assistant_entry = if attachable_assistant_entry?(conversation.last)
        conversation.last
      else
        conversation << { role: "assistant", content: nil, tool_calls: [] }
        conversation.last
      end

      assistant_entry[:tool_calls] ||= []
      assistant_entry[:tool_calls] << tool_call
    end

    def attachable_assistant_entry?(entry)
      entry&.dig(:role) == "assistant" &&
        entry[:tool_call_id].blank? &&
        entry[:tool_name].blank?
    end

    def stamp_aggregate_tokens(assistant_message, aggregate_tokens, model)
      return assistant_message unless assistant_message

      assistant_message.assign_attributes(
        tokens_input: aggregate_tokens[:input],
        tokens_output: aggregate_tokens[:output],
        model: model || assistant_message.model
      )

      assistant_message.save! if assistant_message.changed?
      assistant_message
    end
  end
end
