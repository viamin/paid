# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_THRESHOLD_SECONDS = 10.minutes.to_i

    def self.call(turn:, now: Time.current, threshold: default_threshold)
      new(turn:, now:, threshold:).call
    end

    def self.default_threshold
      seconds = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD_SECONDS).to_i
      (seconds.positive? ? seconds : DEFAULT_THRESHOLD_SECONDS).seconds
    end

    def initialize(turn:, now:, threshold:)
      @turn = turn
      @now = now
      @threshold = threshold
    end

    def call
      turn.with_lock do
        return false unless eligible?

        turn.update!(status: "stalled", detected_stalled_at: now, last_activity_at: now)
        ChatTurns::Track.record_event(turn, "stalled", stalled_at: now.iso8601, side_effecting_tools_completed: side_effecting_tools_completed?)
        create_notice!
      end
      true
    end

    private

    attr_reader :turn, :now, :threshold

    def eligible?
      turn.status.in?(ChatTurn::ACTIVE_STATUSES) && turn.last_activity_at <= now - threshold &&
        !turn.chat_session.rate_limited? && !turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def create_notice!
      turn.chat_session.messages.create!(
        role: "system", chat_turn: turn, content: notice_content,
        metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id,
                    "side_effecting_tools_completed" => side_effecting_tools_completed? }
      )
    end

    def side_effecting_tools_completed?
      turn.messages.where(role: "assistant", tool_status: "approved").exists?
    end

    def notice_content
      "This chat turn stopped responding after its last recorded activity. The transcript above is preserved, " \
        "but no final assistant response was recorded. Review completed tool cards before choosing Resume; " \
        "Paid will not automatically repeat a tool action."
    end
  end
end
