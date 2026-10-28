# frozen_string_literal: true

module ChatTurns
  class Retry
    class UnsafeRecoveryError < ArgumentError; end

    def initialize(chat_turn:, actor:)
      @chat_turn = chat_turn
      @actor = actor
    end

    def self.call(...)
      new(...).call
    end

    def call
      # @spec CHAT-TURN-002
      raise UnsafeRecoveryError, "This turn cannot be retried because tool activity may be repeated" unless chat_turn.claim_retry!

      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: chat_turn.chat_session_id,
        actor_id: actor.id,
        content: chat_turn.user_message.content,
        stream_message_id: chat_turn.stream_message_id
      )
      chat_turn
    end

    private

    attr_reader :chat_turn, :actor
  end
end
