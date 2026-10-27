# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ChatTurn.detectable_stalls(now).find_each.count { |turn| stall(turn) }
    end

    private

    attr_reader :now

    def stall(turn)
      turn.with_lock do
        turn.reload
        return false unless turn.state.in?(%w[pending streaming]) && turn.last_activity_at < now - ChatTurn::STALL_TIMEOUT

        turn.update!(state: "stalled", stalled_at: now, last_activity_at: now)
        persist_notice(turn)
      end
      true
    end

    def persist_notice(turn)
      completed_tools = turn.chat_session.messages.where("id > ?", turn.user_message_id).where(role: "tool").count
      turn.chat_session.messages.create!(
        role: "system",
        content: notice_content(completed_tools),
        metadata: {
          "chat_turn_stalled_notice" => true,
          "chat_turn_id" => turn.id,
          "completed_tool_count" => completed_tools,
          "safe_to_replay" => turn.safe_to_replay?
        }
      )
    end

    def notice_content(completed_tools)
      completed = completed_tools.positive? ? "#{completed_tools} tool result#{'s' if completed_tools != 1} were saved." : "No tool result was saved."
      "This turn stopped without a final assistant response. #{completed} Its remaining work is unknown and requires attention."
    end
  end
end
