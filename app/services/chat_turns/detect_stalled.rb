# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-API-028
  class DetectStalled
    DEFAULT_THRESHOLD = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 30.minutes.to_i).to_i.seconds
    LONG_OPERATION_THRESHOLD = ENV.fetch("CHAT_TURN_LONG_OPERATION_THRESHOLD_SECONDS", 2.hours.to_i).to_i.seconds

    def self.call(...)
      new(...).call
    end

    def initialize(turn:, now:, threshold: DEFAULT_THRESHOLD)
      @turn = turn
      @now = now
      @threshold = threshold
    end

    def call
      return false unless eligible?

      turn.transaction do
        claimed = claim!
        return false unless claimed

        persist_notice!
      end
      log_detection
      true
    end

    private

    attr_reader :turn, :now, :threshold

    def eligible?
      turn.status.in?(%w[pending streaming]) &&
        turn.last_activity_at < now - effective_threshold &&
        !turn.awaiting_confirmation? &&
        !turn.chat_session.rate_limited?
    end

    def effective_threshold
      long_running_operation? ? LONG_OPERATION_THRESHOLD : threshold
    end

    def long_running_operation?
      checkpoint = turn.checkpoint_message
      return false unless checkpoint&.role == "assistant" && checkpoint.tool_call_id.present?

      !turn.chat_session.messages.where(role: "tool", tool_call_id: checkpoint.tool_call_id).exists?
    end

    def claim!
      side_effects = side_effects_completed?
      rows = ChatTurn.where(id: turn.id, status: %w[pending streaming], lock_version: turn.lock_version)
        .update_all(
          status: "stalled",
          stall_classification: "ambiguous_stop",
          detected_at: now,
          side_effects_completed: side_effects,
          lock_version: turn.lock_version + 1,
          updated_at: now
        )
      turn.reload if rows == 1
      rows == 1
    end

    def side_effects_completed?
      calls = turn.chat_session.messages.where(id: turn.user_message_id..).where(role: "assistant")
        .where(tool_status: "approved").where.not(tool_name: nil).pluck(:tool_name)
      calls.any? { |name| Tools::Registry.write_tool?(name) }
    end

    def persist_notice!
      turn.chat_session.messages.create!(
        role: "system",
        content: notice_content,
        metadata: {
          "stalled_turn_id" => turn.id,
          "checkpoint_message_id" => turn.checkpoint_message_id,
          "side_effects_completed" => turn.side_effects_completed
        }
      )
    end

    def notice_content
      completed = turn.checkpoint_message_id ? "Transcript activity was saved through message ##{turn.checkpoint_message_id}." : "The user message was saved."
      effects = turn.side_effects_completed ? "At least one write tool completed, so recovery may repeat a side effect." : "No completed write tool was recorded."
      "This turn stopped without a final assistant response. #{completed} #{effects} What remains is unknown. Review the transcript, then use Resume turn to continue from the durable checkpoint."
    end

    def log_detection
      Rails.logger.warn(
        message: "chat_turn.stalled",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        classification: turn.stall_classification,
        side_effects_completed: turn.side_effects_completed,
        detected_at: turn.detected_at
      )
    end
  end
end
