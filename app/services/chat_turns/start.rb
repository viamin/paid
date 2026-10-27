# frozen_string_literal: true

module ChatTurns
  class Start
    attr_reader :chat_session, :stream_message_id, :user_message, :actor

    def initialize(chat_session:, stream_message_id:, user_message:, actor: nil)
      @chat_session = chat_session
      @stream_message_id = stream_message_id
      @user_message = user_message
      @actor = actor
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-RECOVERY-001
    def call
      turn = chat_session.chat_turns.find_or_create_by!(stream_message_id:) do |record|
        record.status = "pending"
        record.last_activity_at = Time.current
        record.user_message = user_message
        record.actor = actor
      end
      return turn unless turn.status.in?(%w[pending streaming])

      turn.with_lock do
        turn.update!(status: "streaming", user_message:, actor:, last_activity_at: Time.current)
        turn.events.create!(event_type: "started", metadata: {})
      end
      turn
    end
  end
end
