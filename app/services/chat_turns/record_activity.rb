# frozen_string_literal: true

module ChatTurns
  # Records durable activity for the turn a chat message belongs to. Every
  # message persisted inside a turn is evidence that the turn is alive, so the
  # stall detector never has to guess whether a quiet turn is still running.
  #
  # A message belongs to the newest open turn whose user message precedes it.
  #
  # @spec CHAT-TURN-RECOVERY-001
  class RecordActivity
    def self.call(message:)
      new(message).call
    end

    def initialize(message:)
      @message = message
    end

    def call
      turn = open_turn
      return false unless turn

      turn.record_activity!(at: message.created_at)
    end

    private

    attr_reader :message

    def open_turn
      message.chat_session.chat_turns
        .where("user_message_id <= ?", message.id)
        .open
        .order(user_message_id: :desc)
        .first
    end
  end
end
