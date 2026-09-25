# frozen_string_literal: true

module ChatSessions
  # Resumes a chat session that ChatSessions::MarkRateLimited previously
  # paused (CHAT-API-017): re-runs the agent loop against the existing
  # persisted conversation — which already ends in the user's unanswered
  # message, so nothing needs to be resent from the client — clearing the
  # pause on success. If the runner (and every fallback) still rate-limits the
  # retry, the session is re-paused with the new reset time instead of
  # bubbling the error, since this runs unattended from a background sweep.
  # Other exhausted provider errors leave the rate-limit state cleared but
  # persist a durable explanation so clearing the original pause cannot leave
  # the user's pending message silently stranded.
  #
  # Mirrors ChatSessions::ResolveToolCall's use of FallbackLoop: neither host
  # persists a new user message, they just resume the loop.
  class ResumeRateLimited
    include FallbackLoop

    attr_reader :chat_session, :actor, :llm_client, :on_chunk, :on_message_persisted, :stream_message_id

    def initialize(chat_session:, on_chunk: nil, on_message_persisted: nil, llm_client: nil, stream_message_id: nil)
      @chat_session = chat_session
      @actor = chat_session.created_by
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @llm_client = llm_client
      @stream_message_id = stream_message_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHAT-API-017
      chat_session.clear_rate_limit!
      run_with_fallbacks
    rescue AgentHarness::RateLimitError => e
      MarkRateLimited.call(chat_session: chat_session, error: e)
      nil
    rescue AgentHarness::Error => e
      notice = RecordProviderError.call(chat_session: chat_session, error: e)
      on_message_persisted&.call(notice, stream_message_id: stream_message_id)
      nil
    end
  end
end
