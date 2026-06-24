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
    attr_reader :chat_session, :content, :on_chunk, :on_message_persisted, :llm_client, :stream_message_id

    MAX_CONTENT_LENGTH = 12_000

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
      assistant_message = ChatSessions::AgentLoop.new(**loop_kwargs).run
      update_session_activity
      assistant_message
    end

    private

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

    def loop_kwargs
      {
        chat_session: chat_session,
        llm_client: llm_client,
        on_chunk: on_chunk,
        on_message_persisted: on_message_persisted,
        stream_message_id: stream_message_id
      }
    end

    def update_session_activity
      chat_session.update!(
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now
      )
    end
  end
end
