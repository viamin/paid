# frozen_string_literal: true

module ChatTurns
  class Start
    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, user_message:)
      @chat_session = chat_session
      @user_message = user_message
    end

    def call
      ChatTurn.create!(chat_session:, user_message:, status: "pending", last_activity_at: Time.current).tap do |turn|
        turn.events.create!(event_type: "created")
      end
    rescue ActiveRecord::RecordNotUnique
      ChatTurn.find_by!(user_message:)
    end

    private

    attr_reader :chat_session, :user_message
  end
end
