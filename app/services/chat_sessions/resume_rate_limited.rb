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

    attr_reader :chat_session, :actor, :llm_client, :on_chunk, :on_message_persisted, :stream_message_id,
      :transport_attempt_message, :chat_turn

    def initialize(chat_session:, on_chunk: nil, on_message_persisted: nil, llm_client: nil, stream_message_id: nil)
      @chat_session = chat_session
      @actor = chat_session.created_by
      @on_chunk = on_chunk
      @delivery_callback = on_message_persisted
      @llm_client = llm_client
      @stream_message_id = stream_message_id
      @transport_attempt_message = originating_user_message
      @chat_turn = ChatTurn.find_by(user_message: @transport_attempt_message)
      @on_message_persisted = method(:record_persisted_message)
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHAT-API-017
      chat_session.clear_rate_limit!
      start_recovery!
      run_with_fallbacks.tap { |message| conclude_recovery!(message) }
    rescue AgentHarness::RateLimitError => e
      pause_recovery!("rate_limited")
      MarkRateLimited.call(chat_session: chat_session, error: e)
      nil
    rescue AgentHarness::Error => e
      fail_recovery!("provider_failure")
      notice = RecordProviderError.call(chat_session: chat_session, error: e)
      on_message_persisted&.call(notice, stream_message_id: stream_message_id)
      nil
    end

    private

    def extra_agent_loop_kwargs
      { recovery: true }
    end

    def start_recovery!
      return unless chat_turn

      chat_turn.update!(status: "streaming", recovery_attempts: chat_turn.recovery_attempts + 1,
        recovery_outcome: "automatic_running", stall_classification: "rate_limited")
    end

    def record_persisted_message(message, stream_message_id: nil)
      chat_turn&.update!(checkpoint_message: message, last_activity_at: Time.current)
      @delivery_callback&.call(message, stream_message_id: stream_message_id)
    end

    def conclude_recovery!(message)
      return unless chat_turn

      if message
        chat_turn.update!(status: "completed", completed_at: Time.current, recovery_outcome: "automatic_completed")
      else
        chat_turn.update!(status: "pending", recovery_outcome: "awaiting_confirmation",
          metadata: chat_turn.metadata.merge("awaiting_confirmation" => true))
      end
    end

    def pause_recovery!(classification)
      chat_turn&.update!(status: "pending", stall_classification: classification, recovery_outcome: "automatic_deferred")
    end

    def fail_recovery!(classification)
      chat_turn&.update!(status: "failed", stall_classification: classification,
        completed_at: Time.current, recovery_outcome: "automatic_failed")
    end

    # @spec API-CONVERSATION-DELEGATION-002
    def originating_user_message
      chat_session.messages.where(role: "user").order(id: :desc).first
    end
  end
end
