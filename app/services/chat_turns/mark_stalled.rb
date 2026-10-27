# frozen_string_literal: true

module ChatTurns
  class MarkStalled
    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:)
      @chat_turn = chat_turn
    end

    def call
      chat_turn.with_lock do
        return false unless eligible?

        chat_turn.transition_to!("stalled", classification: "no_durable_activity", data: event_data)
        persist_notice
      end
      true
    end

    private

    attr_reader :chat_turn

    def eligible?
      chat_turn.status == "streaming" && chat_turn.last_activity_at <= timeout.ago && !chat_turn.pending_confirmation? && !chat_turn.paused_for_rate_limit?
    end

    def timeout
      setting = chat_turn.chat_session.account.tenant_setting&.chat_stall_timeout_seconds
      setting.present? ? setting.seconds : 10.minutes
    end

    def event_data
      { side_effecting_tools_completed: chat_turn.side_effecting_tools_completed? }
    end

    def persist_notice
      chat_turn.chat_session.messages.create!(
        role: "system",
        content: notice_content,
        metadata: {
          "chat_turn_stalled_notice" => true,
          "chat_turn_id" => chat_turn.id,
          "side_effecting_tools_completed" => chat_turn.side_effecting_tools_completed?
        }
      )
    end

    def notice_content
      "This response stopped without a final assistant message. Previous messages and tool results were preserved. " \
        "No tool will be replayed automatically. Review any completed tool activity, then choose Continue safely to ask the model to continue from this checkpoint."
    end
  end
end
