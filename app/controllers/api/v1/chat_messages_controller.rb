# frozen_string_literal: true

module Api
  module V1
    class ChatMessagesController < BaseController
      include ActionController::Live

      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      before_action -> { require_scope!(:chat) }
      before_action :set_chat_session
      before_action :reject_archived_chat_session, only: %i[create resolve]
      before_action :enforce_chat_rate_limit!, only: %i[create resolve]

      # @spec MOBILE-API-012
      def index
        authorize ChatMessage.new(chat_session: @chat_session), :index?, policy_class: ChatMessagePolicy
        messages = policy_scope(ChatMessage).where(chat_session: @chat_session).includes(:chat_diagram)
        messages = messages.where("chat_messages.id < ?", params[:before]) if params[:before].present?
        page = messages.order(created_at: :desc, id: :desc).limit(message_limit + 1).to_a
        listed = page.first(message_limit).reverse
        payload = { messages: listed.map { |message| message_json(message) } }
        payload[:next_before] = listed.first.id if page.size > message_limit
        render json: payload
      end

      # @spec MOBILE-API-013 CHAT-API-002
      def create
        authorize ChatMessage.new(chat_session: @chat_session), policy_class: ChatMessagePolicy
        return validation_failed("content is required") if params[:content].blank?
        return validation_failed("content exceeds maximum length") if params[:content].to_s.length > ChatSessions::SendMessage::MAX_CONTENT_LENGTH

        sse_requested? ? stream_send : json_send
      end

      # @spec MOBILE-API-014 CHAT-API-004
      def resolve
        tool_call_message = @chat_session.messages.find(params[:id])
        authorize tool_call_message, :resolve?, policy_class: ChatMessagePolicy
        decision = params[:decision].to_s
        return validation_failed("decision must be approve or deny") unless %w[approve deny].include?(decision)

        sse_requested? ? stream_resolve(tool_call_message, decision) : json_resolve(tool_call_message, decision)
      end

      private

      def set_chat_session
        @chat_session = policy_scope(ChatSession).find(params[:session_id])
      end

      def reject_archived_chat_session
        validation_failed("Chat session is archived.") if @chat_session.archived?
      end

      def enforce_chat_rate_limit!
        return unless ChatMessages::RateLimit.exceeded?(user_id: current_user.id, chat_session_id: @chat_session.id)

        response.headers["Retry-After"] = ChatMessages::RateLimit::PERIOD.to_i.to_s
        render_error(:too_many_requests, :rate_limited, "Rate limit exceeded")
      end

      def message_limit
        return DEFAULT_LIMIT if params[:limit].blank?

        params[:limit].to_i.clamp(1, MAX_LIMIT)
      end

      def json_send
        render json: assistant_response(send_message), status: :created
      rescue ChatSessions::TokenLimitExceededError => error
        validation_failed(error.message, details: token_limit_details(error))
      rescue ArgumentError => error
        validation_failed(error.message)
      rescue NotImplementedError, ChatSessions::LlmClientConfigurationError => error
        render_error(:service_unavailable, :provider_unavailable, error.message)
      rescue AgentHarness::RateLimitError => error
        render_error(:too_many_requests, :rate_limited, ChatSessions::ErrorMessage.for(error))
      rescue AgentHarness::Error => error
        render_error(:bad_gateway, :provider_error, ChatSessions::ErrorMessage.for(error))
      end

      def json_resolve(tool_call_message, decision)
        render json: assistant_response(resolve_tool_call(tool_call_message, decision))
      rescue ChatSessions::ResolveToolCall::ResolutionConflictError => error
        render_error(:conflict, :conflict, error.message)
      rescue ArgumentError => error
        validation_failed(error.message)
      rescue NotImplementedError, ChatSessions::LlmClientConfigurationError => error
        render_error(:service_unavailable, :provider_unavailable, error.message)
      rescue AgentHarness::RateLimitError => error
        render_error(:too_many_requests, :rate_limited, ChatSessions::ErrorMessage.for(error))
      rescue AgentHarness::Error => error
        render_error(:bad_gateway, :provider_error, ChatSessions::ErrorMessage.for(error))
      end

      def stream_send
        stream(message_start: { model: @chat_session.model }) do |message_id, on_chunk, on_message_persisted, _on_resolved|
          send_message(on_chunk:, on_message_persisted:)
        end
      end

      def stream_resolve(tool_call_message, decision)
        stream do |_message_id, on_chunk, on_message_persisted, on_resolved|
          resolve_tool_call(tool_call_message, decision, on_chunk:, on_message_persisted:, on_resolved:)
        end
      end

      def stream(message_start: {})
        configure_sse_response
        message_id = SecureRandom.uuid
        write_sse_event("message_start", { message_id: }.merge(message_start))
        chunks = 0
        assistant = yield(message_id, ->(chunk) { chunks += 1; write_sse_event("message_chunk", { message_id:, content: chunk, sequence: chunks }) }, method(:write_sse_tool_event), ->(message) { write_sse_event("message_tool_resolved", tool_resolved_payload(message)) })
        write_sse_event("message_complete", { message_id:, tokens: { input: assistant&.tokens_input, output: assistant&.tokens_output } })
      rescue IOError
        nil
      rescue StandardError => error
        write_sse_event("error", stream_error_payload(error)) rescue IOError
      ensure
        response.stream.close
      end

      def configure_sse_response
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"
      end

      def send_message(on_chunk: nil, on_message_persisted: nil)
        with_chat_session_tenant_context do
          ChatSessions::SendMessage.call(chat_session: @chat_session, actor: current_user, content: params[:content], on_chunk:, on_message_persisted:)
        end
      end

      def resolve_tool_call(tool_call_message, decision, on_chunk: nil, on_message_persisted: nil, on_resolved: nil)
        with_chat_session_tenant_context do
          ChatSessions::ResolveToolCall.call(chat_session: @chat_session, actor: current_user, tool_call_message:, decision:, on_chunk:, on_message_persisted:, on_tool_call_resolved: on_resolved)
        end
      end

      def with_chat_session_tenant_context(&)
        account = TenantContext.with_system_access { Account.find(@chat_session.account_id) }
        TenantContext.with(account, &)
      end

      def sse_requested?
        request.headers["Accept"]&.include?("text/event-stream")
      end

      def validation_failed(message, details: {})
        render_error(:unprocessable_content, :validation_failed, message, details:)
      end

      def assistant_response(message)
        message ? message_json(message) : { status: "paused" }
      end

      def token_limit_details(error)
        { limit_type: error.limit_type, limit: error.limit, used: error.used }.compact
      end

      def token_limit_error_payload(error)
        { error: error.message, limit_type: error.limit_type, limit: error.limit, used: error.used }.compact
      end

      def stream_error_payload(error)
        return token_limit_error_payload(error) if error.is_a?(ChatSessions::TokenLimitExceededError)

        { message: stream_error_message(error) }
      end

      def stream_error_message(error)
        return error.message if error.is_a?(ArgumentError)
        return ChatSessions::ErrorMessage.for(error) if error.is_a?(AgentHarness::Error)

        error.is_a?(NotImplementedError) || error.is_a?(ChatSessions::LlmClientConfigurationError) ? error.message : "An unexpected error occurred"
      end

      def write_sse_event(event, data)
        response.stream.write("event: #{event}\ndata: #{data.to_json}\n\n")
      end

      def write_sse_tool_event(message, stream_message_id: nil)
        return write_sse_event("message_created", message_json(message).merge(fallback_notice: true, stream_message_id: nil)) if message.fallback_notice?
        return write_sse_event("message_created", message_json(message).merge(token_limit_error: true, stream_message_id: nil)) if message.token_limit_error?

        event = message.role == "tool" ? "message_tool_result" : tool_event(message)
        return unless event

        write_sse_event(event, tool_payload(message, stream_message_id:))
      end

      def tool_event(message)
        return unless message.role == "assistant" && message.tool_name.present? && message.content.nil?

        message.pending_confirmation? ? "message_tool_confirmation" : "message_tool_call"
      end

      def tool_payload(message, stream_message_id:)
        { message_id: message.id, role: message.role, tool_name: message.tool_name, tool_call_id: message.tool_call_id,
          tool_arguments: message.tool_arguments, tool_result: message.tool_result, tool_status: message.tool_status, stream_message_id: }
      end

      def tool_resolved_payload(message)
        { message_id: message.id, tool_status: message.tool_status, tool_name: message.tool_name, tool_call_id: message.tool_call_id }
      end

      def message_json(message)
        { id: message.id, external_id: message.external_id, role: message.role, content: message.content, model: message.model,
          tool_call_id: message.tool_call_id, tool_name: message.tool_name, tool_arguments: message.tool_arguments,
          tool_result: message.tool_result, tool_status: message.tool_status, tokens_input: message.tokens_input,
          tokens_output: message.tokens_output, created_at: message.created_at,
          diagram: ChatDiagrams::Serializer.call(message.chat_diagram) }
      end
    end
  end
end
