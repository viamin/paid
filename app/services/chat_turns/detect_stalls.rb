# frozen_string_literal: true

module ChatTurns
  class DetectStalls
    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current, threshold: ChatTurn.stall_threshold)
      @now = now
      @threshold = threshold
    end

    def call
      ChatTurn.inactive_since(now - threshold).find_each.filter_map { |turn| stall(turn) }
    end

    private

    attr_reader :now, :threshold

    def stall(turn)
      return if turn.chat_session.messages.pending_tool_confirmations.exists?
      return unless turn.stall!

      notice = turn.chat_session.messages.create!(role: "system", content: notice_content(turn), metadata: notice_metadata(turn))
      log_stall(turn, notice)
      turn
    end

    def notice_content(turn)
      "This chat turn needs attention. No assistant completion was recorded after its last durable activity at " \
        "#{I18n.l(turn.last_activity_at, format: :long)}. Completed tool results remain in the transcript; any uncompleted work is unknown."
    end

    def notice_metadata(turn)
      pending = turn.chat_session.messages.pending_tool_confirmations.order(:id).pluck(:id)
      { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id, "pending_message_ids" => pending }
    end

    def log_stall(turn, notice)
      Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        detection_time: now.iso8601, notice_message_id: notice.id)
    end
  end
end
