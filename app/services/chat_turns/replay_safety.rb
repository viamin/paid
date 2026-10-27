# frozen_string_literal: true

module ChatTurns
  # A deliberately strict first-release replay contract. Until a tool declares
  # an idempotency contract, only turns with no dispatched tools are safe for
  # unattended recovery.
  # @spec CHAT-TURN-LIFECYCLE-006
  class ReplaySafety
    def self.automatic?(chat_turn)
      !chat_turn.side_effecting_tools_completed &&
        !chat_turn.chat_messages.pending_tool_confirmations.exists? &&
        !chat_turn.chat_messages.where.not(tool_name: nil).exists?
    end
  end
end
