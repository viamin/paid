# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurns
    def initialize(turn:, now: Time.current)
      @turn = turn
      @now = now
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-API-027
    def call
      turn.with_lock do
        return unless stalled_candidate?

        turn.update!(status: "stalled", stalled_at: now, last_activity_at: now,
          metadata: turn.metadata.merge("stall_classification" => "missing_terminal_outcome", "detected_at" => now.iso8601))
        persist_notice
      end
    end

    private

    attr_reader :turn, :now

    def stalled_candidate?
      turn.status.in?(ChatTurn::ACTIVE_STATUSES) &&
        turn.user_message.present? &&
        turn.last_activity_at <= timeout.ago &&
        !awaiting_confirmation? &&
        !rate_limited?
    end

    def timeout
      seconds = turn.chat_session.account.tenant_setting&.chat_turn_stall_timeout
      seconds ? seconds.seconds : TenantSetting::DEFAULT_CHAT_SETTINGS.fetch("chat_turn_stall_timeout").seconds
    end

    def awaiting_confirmation?
      turn.chat_session.messages.pending_tool_confirmations.where("id > ?", turn.user_message_id).exists?
    end

    def rate_limited?
      turn.chat_session.rate_limited_until.present?
    end

    def persist_notice
      turn.chat_session.messages.create!(
        role: "system",
        content: "This request stopped before Paid recorded a final response. Review the request and any tool confirmations before explicitly retrying; no completion has been assumed.",
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "user_message_id" => turn.user_message_id,
          "detected_at" => now.iso8601,
          "completed_tool_message_ids" => completed_tool_message_ids
        }
      )
    end

    def completed_tool_message_ids
      turn.chat_session.messages.where(role: "tool").where("id > ?", turn.user_message_id).pluck(:id)
    end
  end
end
