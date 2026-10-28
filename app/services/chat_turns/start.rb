# frozen_string_literal: true

module ChatTurns
  class Start
    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, user_message:, stream_message_id: nil)
      @chat_session = chat_session
      @user_message = user_message
      @stream_message_id = stream_message_id
    end

    def call
      ChatTurn.find_or_create_by!(user_message: @user_message) do |turn|
        turn.chat_session = @chat_session
        turn.status = "streaming"
        turn.last_activity_at = Time.current
        turn.metadata = { "stream_message_id" => @stream_message_id }.compact
      end.tap { |turn| turn.record!("started", status: "streaming") unless turn.streaming? }
    end
  end
end
