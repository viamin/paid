# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
  class DetectStalls
    def self.call(now: Time.current)
      ChatTurn.stale(now).find_each { |turn| new(turn:, now:).call }
    end

    def initialize(turn:, now:)
      @turn = turn
      @now = now
    end

    def call
      turn.with_lock do
        return unless stallable?

        turn.update!(status: "stalled", classification: "no_durable_activity", detected_at: now,
          metadata: turn.metadata.merge("stalled_at" => now.iso8601, "completed_tool_calls" => completed_tool_calls?))
        create_notice
      end
    end

    private

    attr_reader :turn, :now

    def stallable?
      turn.status.in?(%w[pending streaming]) && turn.activity_at <= now - ChatTurn::STALL_THRESHOLD &&
        !turn.awaiting_confirmation? && !turn.chat_session.rate_limited?
    end

    def completed_tool_calls?
      turn.chat_session.messages.where(role: "tool").where("id > ?", turn.user_message_id).exists?
    end

    def create_notice
      turn.chat_session.messages.create!(
        role: "system",
        content: "This chat turn stopped without a final response. Any completed tool activity is preserved; remaining work is unknown and has not been retried. Review the transcript before continuing.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "user_message_id" => turn.user_message_id }
      )
    end
  end
end
