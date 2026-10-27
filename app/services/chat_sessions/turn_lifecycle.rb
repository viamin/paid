# frozen_string_literal: true

module ChatSessions
  # Durable lifecycle stored on the user message so a lost worker cannot leave
  # an otherwise invisible in-flight turn behind.
  # @spec CHAT-API-027
  class TurnLifecycle
    ACTIVE_STATUSES = %w[pending streaming].freeze
    TERMINAL_STATUSES = %w[completed failed stalled abandoned].freeze

    attr_reader :message

    def self.start!(message)
      lifecycle = new(message)
      lifecycle.send(:transition!, "pending")
      lifecycle
    end

    def self.for_stream(chat_session:, stream_message_id:)
      message = chat_session.messages.find_by(role: "user", metadata: { "stream_message_id" => stream_message_id })
      new(message) if message
    end

    def initialize(message)
      @message = message
    end

    def streaming!
      transition!("streaming")
    end

    def activity!(persisted_message = nil)
      update_turn do |turn|
        turn["last_activity_at"] = Time.current.iso8601
        turn["side_effecting_tool_completed"] = true if side_effecting_tool_result?(persisted_message)
      end
    end

    def complete!(awaiting_confirmation: false)
      transition!("completed", outcome: awaiting_confirmation ? "awaiting_confirmation" : "assistant_response")
    end

    def fail!(classification: "unknown")
      transition!("failed", failure_classification: classification)
    end

    def eligible_to_stall?(cutoff)
      turn = turn_data
      return false unless turn && ACTIVE_STATUSES.include?(turn["status"])
      return false if message.chat_session.rate_limited_until.present?
      return false if message.chat_session.messages.pending_tool_confirmations.exists?

      Time.iso8601(turn.fetch("last_activity_at")) <= cutoff
    rescue KeyError, ArgumentError
      false
    end

    def stall!
      message.with_lock do
        message.reload
        return unless ACTIVE_STATUSES.include?(turn_data&.fetch("status", nil))

        transition!("stalled", detection_time: Time.current.iso8601)
        persist_notice!
      end
    end

    private

    def transition!(status, **attributes)
      update_turn do |turn|
        now = Time.current.iso8601
        turn["status"] = status
        turn["last_activity_at"] = now
        turn["terminal_at"] = now if TERMINAL_STATUSES.include?(status)
        attributes.each { |key, value| turn[key.to_s] = value }
      end
    end

    def update_turn
      return unless message

      data = (message.metadata || {}).deep_dup
      turn = data.fetch("turn", {})
      turn["stream_message_id"] ||= data["stream_message_id"]
      yield turn
      data["turn"] = turn
      message.update!(metadata: data)
    end

    def turn_data
      message&.metadata&.fetch("turn", nil)
    end

    def side_effecting_tool_result?(persisted_message)
      persisted_message&.role == "tool" && Tools::Registry.write_tool?(persisted_message.tool_name)
    end

    def persist_notice!
      return if message.chat_session.messages.where("metadata ->> 'stalled_turn_message_id' = ?", message.id.to_s).exists?

      message.chat_session.messages.create!(
        role: "system",
        content: "This turn stopped responding before Paid recorded a final answer. Completed tool activity remains in the transcript; do not repeat an action until you review it. You can send a follow-up message to continue safely.",
        metadata: {
          "stalled_turn_notice" => true,
          "stalled_turn_message_id" => message.id,
          "side_effecting_tool_completed" => turn_data["side_effecting_tool_completed"] == true
        }
      )
    end
  end
end
