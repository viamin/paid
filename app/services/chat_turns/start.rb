# frozen_string_literal: true

module ChatTurns
  class Start
    # @spec CHAT-TURN-RECOVERY-001
    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, user_message:, actor:, stream_message_id:)
      @chat_session = chat_session
      @user_message = user_message
      @actor = actor
      @stream_message_id = stream_message_id.presence || SecureRandom.uuid
    end

    def call
      ChatTurn.create_or_find_by!(stream_message_id: @stream_message_id) do |turn|
        turn.chat_session = @chat_session
        turn.user_message = @user_message
        turn.actor = @actor
        turn.status = "streaming"
        turn.last_activity_at = Time.current
      end
    end
  end
end
