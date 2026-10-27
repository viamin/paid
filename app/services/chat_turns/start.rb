# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-LIFECYCLE-001
  class Start
    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, user_message:)
      @chat_session = chat_session
      @user_message = user_message
    end

    def call
      turn = user_message.chat_turn || create_turn
      turn.record_activity!(at: user_message.created_at || Time.current)
      turn
    end

    private

    attr_reader :chat_session, :user_message

    def create_turn
      ChatTurn.create!(
        chat_session: chat_session,
        account: chat_session.account,
        user_message: user_message,
        last_activity_at: user_message.created_at || Time.current
      ).tap { |turn| record_started(turn) }
    end

    def record_started(turn)
      ChatTurnEvent.create!(chat_turn: turn, chat_session: chat_session, account: chat_session.account, event_type: "turn_started")
    end
  end
end
