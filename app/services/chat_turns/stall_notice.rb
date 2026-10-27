# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-LIFECYCLE-005
  class StallNotice
    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:)
      @chat_turn = chat_turn
    end

    def call
      return existing_notice if existing_notice

      message = chat_turn.chat_session.messages.create!(
        role: "system",
        chat_turn: chat_turn,
        content: content,
        metadata: { "stall_notice" => true, "chat_turn_id" => chat_turn.id, "classification" => chat_turn.classification,
                    "checkpoint_message_id" => chat_turn.checkpoint_message_id }
      )
      ChatTurnEvent.create!(chat_turn: chat_turn, chat_session: chat_turn.chat_session, account: chat_turn.account,
        event_type: "notice_posted", classification: chat_turn.classification,
        side_effecting_tools_completed: chat_turn.side_effecting_tools_completed)
      message
    end

    private

    attr_reader :chat_turn

    def existing_notice
      chat_turn.chat_session.messages.find_by("metadata ->> 'chat_turn_id' = ? AND metadata ->> 'stall_notice' = 'true'", chat_turn.id.to_s)
    end

    def content
      "This turn stalled after its last saved activity. Completed work is preserved; the remaining response is unknown. " \
        "Review any tool confirmations and choose Resume or Retry to continue safely."
    end
  end
end
