# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_TIMEOUT = 15.minutes

    attr_reader :turn

    def initialize(turn:)
      @turn = turn
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
    def call
      turn.with_lock do
        turn.reload
        return false unless eligible?

        classify!
      end
    end

    def self.timeout
      Integer(ENV.fetch("CHAT_TURN_STALL_TIMEOUT", DEFAULT_TIMEOUT.to_i)).seconds
    rescue ArgumentError
      DEFAULT_TIMEOUT
    end

    private

    def eligible?
      turn.status.in?(%w[pending streaming]) &&
        turn.last_activity_at <= self.class.timeout.ago &&
        !turn.chat_session.rate_limited? &&
        !turn.awaiting_confirmation? &&
        !turn.stall_exempt?
    end

    def classify!
      completed_tools = completed_tool_names
      turn.update!(status: "stalled", stalled_detected_at: Time.current, classification: "no_durable_activity")
      turn.events.create!(event_type: "stalled", metadata: { "classification" => "no_durable_activity", "completed_tools" => completed_tools })
      turn.chat_session.messages.create!(
        role: "system",
        content: notice_content(completed_tools),
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "completed_tools" => completed_tools }
      )
      true
    end

    def completed_tool_names
      turn.chat_session.messages.where(role: "tool").where.not(tool_name: nil).distinct.pluck(:tool_name)
    end

    def notice_content(completed_tools)
      completed = completed_tools.empty? ? "No tool completion was recorded." : "Completed tools: #{completed_tools.join(', ')}."
      "This chat turn stalled after its last durable checkpoint. #{completed} The remaining model work is unknown. Review the preserved tool evidence before retrying; automatic replay is disabled to prevent duplicate side effects."
    end
  end
end
