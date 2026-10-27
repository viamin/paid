# frozen_string_literal: true

module ChatTurns
  class StallDetector
    DEFAULT_THRESHOLD = 10.minutes

    def self.call(now: Time.current, threshold: DEFAULT_THRESHOLD)
      new(now:, threshold:).call
    end

    def initialize(now:, threshold:)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.stale_before(now - threshold).find_each.count { |turn| stall(turn) }
    end

    private

    attr_reader :now, :threshold

    def stall(turn)
      turn.with_lock do
        return false unless turn.active? && turn.activity_at < now - threshold

        turn.update!(status: "stalled", detected_at: now, failure_classification: "no_durable_activity")
        turn.chat_session.messages.create!(role: "system", content: notice_content(turn), metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "side_effecting_tools_completed" => side_effecting_tools_completed?(turn)
        })
        true
      end
    end

    def notice_content(turn)
      "This turn stopped without a final assistant response. Earlier messages and tool activity are preserved. " \
        "#{side_effecting_tools_completed?(turn) ? "A tool may already have changed something; review it before retrying." : "No completed write tool was recorded."}"
    end

    def side_effecting_tools_completed?(turn)
      turn.chat_session.messages.where("id > ?", turn.initiating_message_id)
        .where("role = ? OR tool_name IS NOT NULL", "tool").exists?
    end
  end
end
