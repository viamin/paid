# frozen_string_literal: true

module ChatSessions
  module Turns
    class StallNotice
      # @spec CHAT-TURN-RECOVERY-005
      def self.call(turn:)
        completed = Array(turn.metadata["completed_tools"])
        pending_ids = turn.chat_session.messages.pending_tool_confirmations.pluck(:id)
        turn.chat_session.messages.create!(
          role: "system",
          content: content(turn:, completed:),
          metadata: {
            "stalled_turn_notice" => true,
            "chat_turn_id" => turn.id,
            "turn_revision" => turn.revision,
            "failure_classification" => turn.failure_classification,
            "completed_tools" => completed,
            "side_effecting_tools_completed" => turn.side_effecting_tools_completed?,
            "pending_confirmation_ids" => pending_ids
          }
        )
      end

      def self.content(turn:, completed:)
        completed_text = completed.any? ? "Completed tools: #{completed.join(', ')}." : "No tool result was durably completed."
        uncertainty = turn.side_effecting_tools_completed? ? " A side-effecting action may already have completed; review it before resuming." : " The interrupted step did not produce a known side effect."
        "This turn stopped without a final assistant response (#{turn.failure_classification || 'unknown cause'}). #{completed_text} What remains unknown is whether the interrupted work finished.#{uncertainty} Resume requires attention."
      end
    end
  end
end
