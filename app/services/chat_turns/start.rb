# frozen_string_literal: true

module ChatTurns
  class Start
    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, initiating_message:)
      @chat_session = chat_session
      @initiating_message = initiating_message
    end

    def call
      ChatTurn.find_or_create_by!(initiating_message: @initiating_message) do |turn|
        turn.chat_session = @chat_session
        turn.status = "streaming"
        turn.last_activity_at = Time.current
      end
    end
  end
end
