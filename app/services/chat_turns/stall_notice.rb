# frozen_string_literal: true

module ChatTurns
  class StallNotice
    def initialize(chat_turn:)
      @chat_turn = chat_turn
    end

    def self.call(...)
      new(...).call
    end

    def call
      chat_turn.chat_session.messages.create!(
        role: "system",
        content: content,
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => chat_turn.id,
                    "retryable" => chat_turn.retryable?, "side_effecting_tool_completed" => chat_turn.side_effecting_tool_completed? }
      )
    end

    private

    attr_reader :chat_turn

    def content
      "This chat turn stopped without a final response. Saved messages and tool activity remain in the transcript. " \
        "#{chat_turn.retryable? ? 'No tool activity was recorded; you can safely retry this turn.' : 'Tool activity was recorded or remains uncertain; review it before sending a new request to avoid duplicate side effects.'}"
    end
  end
end
