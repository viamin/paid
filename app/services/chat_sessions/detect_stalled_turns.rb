# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ChatTurn.quiet_before(@now - ChatTurn::STALL_AFTER).find_each.count { |turn| stall(turn) }
    end

    private

    def stall(turn)
      turn.with_lock do
        turn.reload
        return false unless eligible?(turn)

        turn.update!(state: "stalled", classification: "no_durable_activity", detected_at: @now,
          audit_data: turn.audit_data.merge("stalled_at" => @now.iso8601))
        turn.chat_session.messages.create!(role: "system", content: notice_content(turn), metadata: {
          "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "completed_tool_count" => completed_tool_count(turn)
        })
        true
      end
    end

    def eligible?(turn)
      turn.state.in?(%w[pending streaming]) && turn.last_activity_at < @now - ChatTurn::STALL_AFTER &&
        !turn.chat_session.rate_limited? && !turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def completed_tool_count(turn)
      turn.chat_session.messages.where(role: "tool").where("created_at >= ?", turn.created_at).count
    end

    def notice_content(turn)
      count = completed_tool_count(turn)
      "This chat turn stopped without a final assistant response. #{count} tool #{'result'.pluralize(count)} were saved; anything after that is unknown. Review completed tool results and any confirmation cards before retrying so an action is not repeated."
    end
  end
end
