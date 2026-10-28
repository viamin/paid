# frozen_string_literal: true

module ChatTurns
  class DetectStalls
    def self.call(now: Time.current)
      ChatTurn.stale_before(now - ChatTurn::STALL_TIMEOUT).find_each.sum do |turn|
        classify(turn, now:) ? 1 : 0
      end
    end

    def self.classify(turn, now:)
      turn.with_lock do
        turn.reload
        return false unless turn.status.in?(%w[pending streaming]) && turn.last_activity_at <= now - ChatTurn::STALL_TIMEOUT
        return false if turn.pending_confirmation? || turn.known_long_running?

        turn.update!(status: "stalled", stalled_at: now, last_activity_at: now)
        turn.chat_session.messages.create!(
          role: "system",
          content: notice_content(turn),
          metadata: { "chat_turn_stalled" => true, "chat_turn_id" => turn.id, "user_message_id" => turn.user_message_id }
        )
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
        true
      end
    end

    def self.notice_content(turn)
      "This response stopped before a final assistant message was saved. Earlier tool activity remains in the transcript; " \
        "any unfinished work is unknown. Review the tool cards, then explicitly retry if repeating the request is safe."
    end
    private_class_method :notice_content
  end
end
