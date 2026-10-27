# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    def self.call(now: Time.current)
      ChatTurn.stale(now).find_each { |turn| new(turn).call }
    end

    def initialize(turn)
      @turn = turn
    end

    def call
      @turn.with_lock do
        @turn.reload
        return unless @turn.state.in?(%w[pending streaming]) && @turn.activity_at <= ChatTurn::STALL_TIMEOUT.ago
        return if @turn.chat_session.rate_limited?

        @turn.stall!
        persist_notice
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: @turn.id, chat_session_id: @turn.chat_session_id)
      end
    end

    private

    def persist_notice
      @turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before it reached a final answer. Any completed tool activity is preserved above; no unfinished action was assumed successful. Review the transcript and retry only if it is safe to repeat the request.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => @turn.id, "user_message_id" => @turn.user_message_id }
      )
    end
  end
end
