# frozen_string_literal: true

module ChatTurns
  # Finds (or opens) the durable turn for a user message. A user message is the
  # anchor of exactly one turn: a fresh send opens a new turn, while a recovery
  # re-opens the turn that already owns the message.
  #
  # @spec CHAT-TURN-RECOVERY-001
  class OpenTurn
    def self.call(chat_session:, user_message:)
      new(chat_session:, user_message:).call
    end

    def initialize(chat_session:, user_message:)
      @chat_session = chat_session
      @user_message = user_message
    end

    def call
      turn = find_or_create_turn
      turn.reopen! if turn.recoverable?
      turn
    end

    private

    attr_reader :chat_session, :user_message

    def find_or_create_turn
      ChatTurn.find_by(user_message_id: user_message.id) || create_turn
    end

    def create_turn
      ChatTurn.create!(
        chat_session: chat_session,
        user_message: user_message,
        state: "pending",
        last_activity_at: user_message.created_at
      )
    rescue ActiveRecord::RecordNotUnique
      # A concurrent send for the same message won the unique index.
      ChatTurn.find_by!(user_message_id: user_message.id)
    end
  end
end
