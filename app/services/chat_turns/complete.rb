# frozen_string_literal: true

module ChatTurns
  class Complete
    attr_reader :turn, :assistant_message

    def initialize(turn:, assistant_message:)
      @turn = turn
      @assistant_message = assistant_message
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-RECOVERY-001
    def call
      turn.with_lock do
        if assistant_message.nil? && turn.awaiting_confirmation?
          turn.update!(status: "pending", last_activity_at: Time.current)
          turn.events.create!(event_type: "awaiting_confirmation", metadata: {})
        else
          turn.update!(status: "completed", last_activity_at: Time.current)
          turn.events.create!(event_type: "completed", metadata: { "assistant_message_id" => assistant_message&.id })
        end
      end
    end
  end
end
