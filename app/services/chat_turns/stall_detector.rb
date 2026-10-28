# frozen_string_literal: true

module ChatTurns
  class StallDetector
    def self.call(now: Time.current)
      ChatTurn.detectable.where(activity_at: ...now - ChatTurn::STALL_THRESHOLD).find_each do |chat_turn|
        chat_turn.with_lock do
          next unless chat_turn.state == "streaming"
          next unless chat_turn.activity_at < now - ChatTurn::STALL_THRESHOLD
          next if chat_turn.chat_session.rate_limited?
          next if chat_turn.chat_session.messages.pending_tool_confirmations.exists?

          chat_turn.stalled!
          chat_turn.messages.create!(
            role: "system",
            content: "This response stopped before a final answer was saved. Completed tool activity remains in the transcript; anything after the last saved item is unknown. Review the tool cards before resuming.",
            metadata: { "stalled_turn_notice" => true, "chat_turn_id" => chat_turn.id }
          )
          Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: chat_turn.id, chat_session_id: chat_turn.chat_session_id)
        end
      end
    end
  end
end
