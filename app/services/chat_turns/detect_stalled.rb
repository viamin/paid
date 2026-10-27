# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-API-027
  # Marks only turns that stopped making durable progress. Pending human
  # confirmation and a known rate-limit pause are intentional waits, not
  # failures, and are never converted to a stalled state.
  class DetectStalled
    def self.call(now: Time.current, timeout: ChatTurn::STALL_TIMEOUT)
      new(now:, timeout:).call
    end

    def initialize(now:, timeout:)
      @now = now
      @timeout = timeout
    end

    def call
      ChatTurn.stale_before(now - timeout).find_each.filter_map { |turn| stall(turn) }
    end

    private

    attr_reader :now, :timeout

    def stall(turn)
      turn.with_lock do
        turn.reload
        return unless eligible?(turn)

        turn.stall!
        notice = create_notice(turn)
        log_stall(turn)
        [ turn, notice ]
      end
    end

    def eligible?(turn)
      turn.status.in?(%w[pending streaming]) &&
        turn.last_activity_at < now - timeout &&
        !turn.pending_confirmation? &&
        !turn.rate_limited?
    end

    def create_notice(turn)
      turn.chat_session.messages.create!(
        chat_turn: turn,
        role: "system",
        content: notice_content(turn),
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "stall_classification" => turn.stall_classification,
          "side_effecting_tools_completed" => turn.side_effecting_tools_completed?
        }
      )
    end

    def notice_content(turn)
      completed = turn.side_effecting_tools_completed? ? "Some tool activity completed before progress stopped." : "No completed side-effecting tool was recorded."
      "This chat turn appears to have stalled. #{completed} The final assistant response is unknown. Review the preserved tool activity before retrying; Paid will not replay tools automatically."
    end

    def log_stall(turn)
      Rails.logger.warn(
        message: "chat_turn.stalled",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        classification: turn.stall_classification,
        side_effecting_tools_completed: turn.side_effecting_tools_completed?
      )
    end
  end
end
