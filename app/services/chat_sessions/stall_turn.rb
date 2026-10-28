# frozen_string_literal: true

module ChatSessions
  class StallTurn
    REASON = "durable_activity_timeout"

    def self.call(...)
      new(...).call
    end

    def initialize(turn:)
      @turn = turn
    end

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
    def call
      return false unless turn.stall!(detected_at: Time.current, reason: REASON)

      create_notice
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        classification: REASON, side_effecting_tools_completed: side_effecting_tools_completed?)
      true
    end

    private

    attr_reader :turn

    def create_notice
      turn.chat_session.messages.create!(
        chat_turn: turn,
        role: "system",
        content: "This turn stopped without a final assistant response. Completed tool activity is preserved below; any remaining work is unknown. Review completed actions before starting a new request so no side-effecting tool is repeated.",
        metadata: {
          "stalled_turn_notice" => true,
          "turn_id" => turn.id,
          "classification" => REASON,
          "side_effecting_tools_completed" => side_effecting_tools_completed?
        }
      )
    end

    def side_effecting_tools_completed?
      turn.chat_messages.where(role: "tool").joins(:chat_turn).exists?
    end
  end
end
