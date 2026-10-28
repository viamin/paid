# frozen_string_literal: true

module ChatTurns
  class Start
    # @spec CHAT-TURN-RECOVERY-001
    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, initiating_message:, actor:, stream_message_id: nil)
      @chat_session = chat_session
      @initiating_message = initiating_message
      @actor = actor
      @stream_message_id = stream_message_id
    end

    def call
      turn = stream_message_id.blank? ? chat_session.chat_turns.build : chat_session.chat_turns.find_or_initialize_by(stream_message_id:)
      turn.update!(initiating_message:, actor:, status: "streaming", last_activity_at: Time.current)
      turn
    end

    private

    attr_reader :actor, :chat_session, :initiating_message, :stream_message_id
  end
end
