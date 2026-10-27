# frozen_string_literal: true

module ChatTurns
  class DetectStalled
    DEFAULT_TIMEOUT = 10.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current, timeout: self.class.timeout_from_environment)
      @now = now
      @timeout = timeout
    end

    def call
      ChatTurn.detectable.where(last_activity_at: ..(@now - @timeout)).find_each do |turn|
        classify(turn)
      end
    end

    private

    def classify(turn)
      turn.with_lock do
        return unless stale?(turn)
        return if deliberately_waiting?(turn)

        notice = turn.chat_session.messages.create!(role: "system", content: notice_content(turn), metadata: notice_metadata(turn))
        turn.update!(
          status: "stalled",
          classification: "durable_activity_timeout",
          detection_at: @now,
          last_activity_at: @now,
          metadata: notice.metadata
        )
        log_stall(turn)
      end
    end

    def stale?(turn)
      turn.status.in?(%w[pending streaming]) && turn.last_activity_at <= (@now - @timeout)
    end

    def deliberately_waiting?(turn)
      turn.chat_session.rate_limited? || turn.messages.pending_tool_confirmations.exists? || turn.metadata.fetch("long_running_until", Time.at(0)).then { |time| Time.parse(time.to_s) > @now }
    rescue ArgumentError
      false
    end

    def notice_metadata(turn)
      messages = turn.messages.order(:id)
      {
        "stalled_turn_notice" => true,
        "chat_turn_id" => turn.id,
        "tool_message_ids" => messages.where.not(tool_name: nil).pluck(:id),
        "side_effecting_tools_completed" => messages.where(role: "tool").exists?
      }
    end

    def notice_content(turn)
      "This turn stopped without a final response. Your request and completed tool activity are preserved. " \
        "The remaining model work is unknown. Review any tool confirmations, then explicitly resume only if it is safe to continue."
    end

    def log_stall(turn)
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        classification: turn.classification, side_effecting_tools_completed: turn.metadata["side_effecting_tools_completed"])
    end

    def self.timeout_from_environment
      value = ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", DEFAULT_TIMEOUT.to_i).to_i
      value.positive? ? value.seconds : DEFAULT_TIMEOUT
    end
  end
end
