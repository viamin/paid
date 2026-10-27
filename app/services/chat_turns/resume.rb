# frozen_string_literal: true

module ChatTurns
  class Resume
    include ChatSessions::FallbackLoop

    attr_reader :turn, :chat_session, :actor, :llm_client, :on_chunk, :stream_message_id,
      :transport_attempt_message

    def initialize(turn:, actor:, on_chunk: nil, on_message_persisted: nil, stream_message_id: nil)
      @turn = turn
      @chat_session = turn.chat_session
      @actor = actor
      @on_chunk = on_chunk
      @broadcast_message = on_message_persisted
      @stream_message_id = stream_message_id
      @transport_attempt_message = turn.user_message
    end

    # @spec CHAT-TURN-RECOVERY-004
    def call
      assistant_message = run_with_fallbacks
      ChatTurns::Track.completed!(turn, awaiting_confirmation: assistant_message.nil?)
      assistant_message
    rescue StandardError => e
      ChatTurns::Track.failed!(turn, error: e)
      raise
    end

    private

    def record_persisted_message(message)
      ChatTurns::Track.activity!(turn, message:)
      @broadcast_message&.call(message)
    end

    def on_message_persisted
      method(:record_persisted_message)
    end
  end
end
