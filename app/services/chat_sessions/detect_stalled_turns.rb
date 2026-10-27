# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(now: Time.current, threshold: configured_threshold)
      ChatTurn.detectable(now - threshold).find_each { |turn| new(turn, now:).call }
    end

    def self.configured_threshold
      seconds = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i
      seconds.positive? ? seconds.seconds : DEFAULT_THRESHOLD
    end

    def initialize(turn, now:)
      @turn = turn
      @now = now
    end

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    def call
      @turn.with_lock do
        return unless @turn.status.in?(%w[pending streaming])
        return if @turn.activity_at > @now - self.class.configured_threshold
        return if @turn.chat_session.rate_limited? || @turn.pending_confirmation?

        @turn.stall!
        persist_notice
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: @turn.id, chat_session_id: @turn.chat_session_id,
          side_effecting_tools_completed: side_effecting_tools_completed?)
      end
    end

    private

    def persist_notice
      @turn.chat_session.messages.create!(role: "system", content: notice_content, metadata: {
        "stalled_turn_notice" => true, "chat_turn_id" => @turn.id,
        "side_effecting_tools_completed" => side_effecting_tools_completed?
      })
    end

    def notice_content
      "This response stopped before a final answer was saved. Earlier messages and tool results are preserved, but the remaining work is unknown. " \
        "Review the tool cards before continuing. To avoid repeating an action, recovery will not automatically replay tools; send a new message when you are ready to continue."
    end

    def side_effecting_tools_completed?
      @turn.chat_session.messages.where(role: "assistant", tool_status: "approved").where("created_at >= ?", @turn.user_message&.created_at || @turn.created_at).exists?
    end
  end
end
