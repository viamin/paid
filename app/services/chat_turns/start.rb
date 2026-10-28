# frozen_string_literal: true

module ChatTurns
  class Start
    def initialize(chat_session:, actor:, user_message:, stream_message_id: nil)
      @chat_session = chat_session
      @actor = actor
      @user_message = user_message
      @stream_message_id = stream_message_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      turn = stream_message_id && ChatTurn.find_by(stream_message_id: stream_message_id)
      return turn if turn

      ChatTurn.create!(chat_session:, actor:, user_message:, stream_message_id:, last_activity_at: Time.current).tap(&:start!)
    end

    private

    attr_reader :chat_session, :actor, :user_message, :stream_message_id
  end
end
