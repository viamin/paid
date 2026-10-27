# frozen_string_literal: true

module ChatTurns
  class RecordActivity
    attr_reader :turn, :message

    def initialize(turn:, message:)
      @turn = turn
      @message = message
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-RECOVERY-001
    def call
      turn.with_lock do
        turn.update!(user_message: message, last_activity_at: Time.current) if message.role == "user"
        turn.update!(last_activity_at: Time.current) unless message.role == "user"
        turn.update!(side_effecting_tool_persisted: true) if side_effecting_tool_message?
        turn.events.create!(event_type: "activity", metadata: { "message_id" => message.id, "role" => message.role })
      end
    end

    private

    def side_effecting_tool_message?
      message.tool_name.present? && Tools::Registry.write_tool?(message.tool_name)
    end
  end
end
