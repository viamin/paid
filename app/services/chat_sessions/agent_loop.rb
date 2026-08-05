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

    DEFAULT_MAX_TOOL_ITERATIONS = 50
    MAX_CONVERSATION_MESSAGES = 200
    EMPTY_RESPONSE_MESSAGE = "I couldn't complete that turn because the model returned an empty response. Please try again."
    SOFT_STOP_PROMPT = "You've reached the maximum number of tool calls for this turn. Summarize what you've found so far and suggest what the user should do next. Do not call any more tools."
    SOFT_STOP_FALLBACK_MESSAGE = "I've reached the maximum number of tool calls for this turn. Please send another message to continue."

    attr_reader :chat_session, :llm_client, :on_chunk, :on_message_persisted, :stream_message_id,
      :created_message_ids

    def initialize(chat_session:, llm_client:, on_chunk: nil, on_message_persisted: nil, stream_message_id: nil,
      token_budget: nil)
      @chat_session = chat_session
      @llm_client = llm_client
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @stream_message_id = stream_message_id
      @created_message_ids = []
      @token_budget_override = token_budget
    end

    # @return [ChatMessage, nil] the final assistant message, or +nil+ when the
    #   loop paused to await confirmation for a write tool.
    def run
      # @spec CHAT-API-003
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
      limit = max_tool_iterations
      budget = token_budget

      limit.times do |iteration|
        conversation = trim_conversation(conversation)
        response = call_llm(conversation)
        aggregate_tokens[:input] += response[:tokens_input].to_i
        aggregate_tokens[:output] += response[:tokens_output].to_i
        last_response_model = response[:model]

        if response[:tool_calls].blank?
          final_assistant_message = create_assistant_message(response) if response[:content].present?
          final_assistant_message ||= create_empty_response_message(
            model: last_response_model,
            aggregate_tokens: aggregate_tokens
          )
          break
        end

        # Check budget BEFORE persisting the response or processing tools. This
        # prevents an orphaned assistant message that promises a tool action the
        # loop will never execute. Stop on equality as well: once aggregate usage
        # reaches the remaining budget there is nothing left for another
        # LLM round-trip, so continuing would overrun the configured limit.
        if budget && (aggregate_tokens[:input] + aggregate_tokens[:output]) >= budget
          final_assistant_message = run_soft_stop(conversation, aggregate_tokens:, model: last_response_model)
          break
        end

        final_assistant_message = create_assistant_message(response) if response[:content].present?

        conversation << {
          role: "assistant",
          content: response[:content],
          tool_calls: response[:tool_calls]
        }

        read_only_calls, write_calls = partition_tool_calls(response[:tool_calls])

        read_only_calls.each do |tool_call|
          tool_result = process_tool_call(tool_call)

          conversation << {
            role: "tool",
            content: tool_result,
            tool_call_id: tool_call[:id],
            tool_name: tool_call[:name]
          }
        end

        executed_write_results, paused_for_confirmation = process_write_tool_calls(write_calls)
        executed_write_results.each do |tool_call, tool_result|
          conversation << {
            role: "tool",
            content: tool_result,
            tool_call_id: tool_call[:id],
            tool_name: tool_call[:name]
          }
        end

        if paused_for_confirmation
          return pause_for_confirmation(aggregate_tokens:, model: last_response_model)
        end

        next unless iteration == (limit - 1)

        final_assistant_message = run_soft_stop(conversation, aggregate_tokens:, model: last_response_model)
      end

      stamp_aggregate_tokens(final_assistant_message, aggregate_tokens, last_response_model)
    end

    def max_tool_iterations
      @max_tool_iterations ||= begin
        limit = chat_session.account.tenant_setting&.chat_max_tool_iterations
        (limit.is_a?(Integer) && limit.positive?) ? limit : DEFAULT_MAX_TOOL_ITERATIONS
      end
    end

    # Injects a wrap-up instruction and calls the model one final time without
    # tools so it must produce a text summary. Used both when the iteration cap
    # is reached and when the token budget is exhausted mid-loop.
    def run_soft_stop(conversation, aggregate_tokens:, model:)
      conversation << { role: "user", content: SOFT_STOP_PROMPT }

      response = call_llm(conversation, exclude_tools: true)
      aggregate_tokens[:input] += response[:tokens_input].to_i
      aggregate_tokens[:output] += response[:tokens_output].to_i

      create_assistant_message(
        content: response[:content].presence || SOFT_STOP_FALLBACK_MESSAGE,
        model: response[:model] || model
      )
    end

    # The remaining token budget for the turn. Callers that already ran the
    # pre-loop guard (SendMessage#check_token_limit!) pass the value via the
    # `token_budget:` constructor arg to avoid a redundant SUM aggregation per
    # turn. Callers without a pre-loop guard (ResolveToolCall, or direct
    # AgentLoop use) leave it unset and we fetch it once here. Fail-open on DB
    # errors: a transient failure degrades to no mid-loop budget enforcement
    # rather than aborting a healthy turn — the pre-loop
    # SendMessage#check_token_limit! provides the first line of defense.
    def token_budget
      return @token_budget if defined?(@token_budget)

      @token_budget = @token_budget_override || fetch_token_budget
    end

    def fetch_token_budget
      ChatSessions::CheckTokenLimit.call(chat_session: chat_session)[:remaining_tokens]
    rescue => e
      Rails.logger.warn(
        message: "chat_agent_loop.token_budget_check_failed",
        chat_session_id: chat_session.id,
        error: e.class.name
      )
      nil
    end

    # Bounds the conversation sent to the LLM so a long tool-driven turn cannot
    # grow it past MAX_CONVERSATION_MESSAGES. build_conversation already caps the
    # persisted history; this trims the in-turn entries the loop appends. Leading
    # tool results are dropped so the window never starts with an orphaned tool
    # message whose matching assistant tool_calls were trimmed away.
    def trim_conversation(conversation)
      return conversation if conversation.length <= MAX_CONVERSATION_MESSAGES

      conversation.last(MAX_CONVERSATION_MESSAGES).drop_while { |entry| entry[:role] == "tool" }
    end

    # When the model requests one or more write tools in a batch, run the
    # read-only calls in that same batch immediately (so their results are not
    # lost) and surface *every* write tool as a pending confirmation, then stop
    # the loop so a human can approve or deny each. Resolving one write tool at a
    # time is safe because `ResolveToolCall` only resumes the loop once the last
    # pending confirmation is settled — the rebuilt conversation never contains an
    # unanswered tool call. See RDR-028.
    def pause_for_confirmation(aggregate_tokens:, model:)
      # @spec CHAT-API-003
      record_token_usage(aggregate_tokens[:input], aggregate_tokens[:output], model:)
      nil
    end

    # Executes a single tool call: persists the request row, dispatches the tool,
    # and persists the result. Shared by the inline (read-only) path and the
    # read-only portion of a mixed batch that pauses for write confirmation.
    def process_tool_call(tool_call)
      persist_tool_call_message(tool_call)

      tool_result = dispatch_tool(name: tool_call[:name], arguments: parse_tool_arguments(tool_call))
      persist_tool_result_message(tool_call, tool_result)
      tool_result
    end

    def pending_write_tool?(tool_calls)
      tool_calls.any? { |tool_call| Tools::Registry.write_tool?(tool_call[:name]) }
    end

    def partition_tool_calls(tool_calls)
      tool_calls.partition { |tool_call| !Tools::Registry.write_tool?(tool_call[:name]) }
    end

    def process_write_tool_calls(write_calls)
      # @spec CHAT-API-003
      executed_results = []
      paused_for_confirmation = false

      auto_approved, manual_confirmation = partition_auto_approved(write_calls)
      executed_results.concat(auto_approve_write_tool_calls(auto_approved))

      manual_confirmation.each do |tool_call|
        if Tools::Registry.post_dispatch_confirmation?(tool_call[:name])
          tool_result = dispatch_tool(name: tool_call[:name], arguments: parse_tool_arguments(tool_call))

          if ready_for_post_dispatch_confirmation?(tool_result)
            persist_pending_tool_call_message(tool_call, tool_result:)
            paused_for_confirmation = true
          else
            persist_tool_call_message(tool_call)
            persist_tool_result_message(tool_call, tool_result)
            executed_results << [ tool_call, tool_result ]
          end
        else
          persist_pending_tool_call_message(tool_call)
          paused_for_confirmation = true
        end
      end

      [ executed_results, paused_for_confirmation ]
    end

    # Splits a write-tool batch into tools the per-session auto-approve toggle
    # covers vs. tools that still require an explicit human confirmation. The
    # toggle is intentionally scoped to `trigger_agent_run` (issue #2894):
    # agent-run creation is the workflow's primary reason to want hands-off
    # approvals, while broader mutations (settings, memberships, API keys,
    # CIRs, etc.) keep RDR-028's manual-confirmation default so we do not
    # silently widen the blast radius of a single checkbox.
    def partition_auto_approved(write_calls)
      write_calls.partition { |tool_call| auto_approve_eligible?(tool_call[:name]) }
    end

    def auto_approve_eligible?(tool_name)
      chat_session.auto_approve? && tool_name == "trigger_agent_run"
    end

    # With auto-approve enabled for a covered tool, the write tool is
    # authorized and dispatched immediately instead of pausing for a manual
    # click. The session owner opted in per-session, so RDR-028's default is
    # not weakened — authorization is still re-checked by Pundit at dispatch
    # time, and +confirmed+ never originates from the model itself (it is
    # injected here, exactly as ResolveToolCall does on a human approval).
    #
    # For post-dispatch tools, if the confirmation resolution returns a
    # structured error, the row stays `pending` (mirroring the manual path in
    # ResolveToolCall#rollback_to_pending) so the failed draft is retriable
    # instead of being stranded behind an `approved` row this service will
    # never touch again.
    def auto_approve_write_tool_calls(write_calls)
      write_calls.map do |tool_call|
        tool_result = dispatch_auto_approved_tool(tool_call)
        persist_auto_approved_tool_call(tool_call, tool_result)
        [ tool_call, tool_result ]
      end
    end

    def persist_auto_approved_tool_call(tool_call, tool_result)
      if Tools::Registry.post_dispatch_confirmation?(tool_call[:name]) && error_result?(tool_result)
        persist_pending_tool_call_message(tool_call, tool_result: tool_result)
      else
        persist_tool_call_message(tool_call, status: "approved")
        persist_tool_result_message(tool_call, tool_result)
      end
    end

    def dispatch_auto_approved_tool(tool_call)
      name = tool_call[:name]
      arguments = parse_tool_arguments(tool_call)

      return dispatch_tool(name: name, arguments: arguments.merge("confirmed" => true)) unless Tools::Registry.post_dispatch_confirmation?(name)

      draft_result = dispatch_tool(name: name, arguments: arguments)
      return draft_result unless ready_for_post_dispatch_confirmation?(draft_result)

      resolve_tool_confirmation(name: name, decision: :approve, pending_result: draft_result)
    end

    # Mirrors ResolveToolCall#error_result?: a post-dispatch tool whose
    # confirmation resolution returned a structured error must stay pending so
    # a human can retry — same failure semantics as the manual confirmation
    # path. Marking the row `approved` would strand the failed draft behind a
    # status that this service (and ResolveToolCall) will never pick up again.
    def error_result?(result)
      return false unless result.is_a?(Hash)

      tool_result_value(result, :status) == "error"
    end

    def ready_for_post_dispatch_confirmation?(tool_result)
      return false unless tool_result.is_a?(Hash)

      tool_result_value(tool_result, :id).present? && tool_result_value(tool_result, :status) == "draft"
    end

    def tool_result_value(tool_result, key)
      tool_result[key] || tool_result[key.to_s]
    end

    def build_conversation
      messages = chat_session.messages.chronological
      messages = messages.last(MAX_CONVERSATION_MESSAGES)

      messages.each_with_object([]) do |msg, conversation|
        next if msg.fallback_notice?

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

    def call_llm(conversation, exclude_tools: false)
      chunk_streamed = false
      chunk_callback = lambda do |chunk|
        next if chunk.blank?

        chunk_streamed = true
        on_chunk&.call(chunk)
      end

      if llm_client
        invoke_llm_client(conversation, chunk_callback, exclude_tools: exclude_tools).tap do |response|
          replay_response_content(response, chunk_callback) unless chunk_streamed
        end
      else
        raise NotImplementedError, "agent-harness chat transport not yet integrated"
      end
    end

    def invoke_llm_client(conversation, chunk_callback, exclude_tools: false)
      call_llm_client(
        conversation,
        include_tools: !exclude_tools && llm_client_supports_tools?,
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
      @tool_definitions ||= Tools::Registry.chat_definitions_for(user: chat_session.created_by, session: chat_session)
    end

    def create_assistant_message(response)
      message = chat_session.messages.create!(
        role: "assistant",
        content: response[:content],
        model: response[:model],
        tokens_input: response[:tokens_input],
        tokens_output: response[:tokens_output]
      )

      track_created_message(message)
      on_message_persisted&.call(message, stream_message_id: stream_message_id)
      message
    end

    def create_empty_response_message(model:, aggregate_tokens:)
      log_empty_response(model:, aggregate_tokens:)

      create_assistant_message(
        content: EMPTY_RESPONSE_MESSAGE,
        model: model,
        tokens_input: aggregate_tokens[:input],
        tokens_output: aggregate_tokens[:output]
      )
    end

    def log_empty_response(model:, aggregate_tokens:)
      Rails.logger.warn(
        message: "chat_agent_loop.empty_response",
        chat_session_id: chat_session.id,
        project_id: chat_session.project_id,
        runner_id: chat_session.runner_id,
        model: model,
        tokens_input: aggregate_tokens[:input],
        tokens_output: aggregate_tokens[:output]
      )
    end

    def persist_tool_call_message(tool_call, status: nil, tool_result: nil)
      tool_call_message = chat_session.messages.create!(
        role: "assistant",
        content: nil,
        tool_name: tool_call[:name],
        tool_arguments: parse_tool_arguments(tool_call),
        tool_call_id: tool_call[:id],
        tool_status: status,
        tool_result: tool_result
      )

      track_created_message(tool_call_message)
      on_message_persisted&.call(tool_call_message)
      tool_call_message
    end

    def persist_pending_tool_call_message(tool_call, tool_result: nil)
      persist_tool_call_message(tool_call, status: "pending", tool_result:)
    end

    def persist_tool_result_message(tool_call, tool_result)
      tool_result_message = chat_session.messages.create!(
        role: "tool",
        content: tool_result.to_json,
        tool_result: tool_result,
        tool_call_id: tool_call[:id],
        tool_name: tool_call[:name]
      )

      track_created_message(tool_result_message)
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

    # Records the id of every row this attempt persists so FallbackLoop can roll
    # back exactly the failed attempt's messages (see
    # FallbackLoop#discard_partial_attempt) instead of every row created after a
    # checkpoint — the latter would also delete a concurrent turn's messages,
    # since neither SendMessage nor ResolveToolCall locks the session.
    def track_created_message(message)
      @created_message_ids << message.id
      message
    end

    def finalize_token_usage(assistant_message)
      record_token_usage(
        assistant_message.tokens_input.to_i,
        assistant_message.tokens_output.to_i,
        model: assistant_message.model
      )
    end

    # Persists a TokenUsage/cost row for the turn. Shared by the normal path
    # (via `finalize_token_usage`) and the write-tool pause path so the LLM
    # turn that *requested* a confirmation is never lost from cost tracking.
    def record_token_usage(input_tokens, output_tokens, model:)
      return unless input_tokens.to_i.positive? || output_tokens.to_i.positive?

      cost_cents = TokenUsageTracker.calculate_cost(input_tokens, output_tokens, llm_model: model)

      TenantContext.with_system_access do
        TokenUsage.create!(
          chat_session_id: chat_session.id,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost_cents: cost_cents,
          llm_model: model,
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
