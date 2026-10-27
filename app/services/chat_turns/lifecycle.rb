# frozen_string_literal: true

module ChatTurns
  class Lifecycle
    # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-002, CHAT-TURN-RECOVERY-003
    class << self
      def start!(chat_session:, stream_message_id:)
        turn = ChatTurn.find_or_create_by!(chat_session:, stream_message_id:) do |record|
          record.status = "pending"
          record.last_activity_at = Time.current
        end
        turn.update!(status: "streaming", last_activity_at: Time.current) if turn.status == "pending"
        turn
      end

      def record_activity!(turn:, message:)
        attributes = { last_activity_at: Time.current }
        attributes[:user_message] = message if message.role == "user"
        attributes[:side_effecting_tool_completed] = true if side_effecting_tool_result?(message)
        turn.update!(attributes)
      end

      def complete!(turn:)
        turn.update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
      end

      def await_confirmation!(turn:)
        turn.update!(status: "awaiting_confirmation", last_activity_at: Time.current)
      end

      def fail!(turn:, classification:)
        turn.update!(status: "failed", failure_classification: classification, completed_at: Time.current, last_activity_at: Time.current)
      end

      def stall!(turn:)
        turn.with_lock do
          return unless eligible_for_stall?(turn)

          turn.update!(status: "stalled", stalled_at: Time.current)
          turn.chat_session.messages.create!(
            role: "system",
            content: notice_content(turn),
            metadata: {
              "stalled_turn_notice" => true,
              "chat_turn_id" => turn.id,
              "side_effecting_tool_completed" => turn.side_effecting_tool_completed?
            }
          )
          turn
        end
      end

      private

      def eligible_for_stall?(turn)
        turn.status == "streaming" && !turn.chat_session.rate_limited? &&
          !turn.chat_session.messages.pending_tool_confirmations.exists?
      end

      def side_effecting_tool_result?(message)
        message.role == "tool" && Tools::Registry.write_tool?(message.tool_name)
      end

      def notice_content(turn)
        completed = turn.side_effecting_tool_completed? ? "A side-effecting tool completed; do not replay it blindly." : "No completed side-effecting tool was recorded."
        "This turn stopped without a final assistant response. #{completed} Review the preserved tool activity before retrying."
      end
    end
  end
end
