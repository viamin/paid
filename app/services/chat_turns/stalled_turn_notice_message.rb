# frozen_string_literal: true

module ChatTurns
  # Builds the persisted system-message content and metadata explaining that
  # a chat turn stalled (#4680): what completed, what remains unknown, and
  # why it needs attention. Mirrors ChatSessions::TokenLimitErrorMessage /
  # RateLimitPauseMessage so the explanation survives reload.
  class StalledTurnNoticeMessage
    Result = Data.define(:content, :metadata)

    def self.build(chat_turn:, automatic_recovery_attempted:)
      new(chat_turn: chat_turn, automatic_recovery_attempted: automatic_recovery_attempted).build
    end

    def initialize(chat_turn:, automatic_recovery_attempted:)
      @chat_turn = chat_turn
      @automatic_recovery_attempted = automatic_recovery_attempted
    end

    def build
      Result.new(content: content, metadata: metadata)
    end

    private

    attr_reader :chat_turn, :automatic_recovery_attempted

    def content
      [ headline, activity_line, guidance ].compact.join("\n\n")
    end

    def headline
      "This turn stalled: no further activity was recorded for over " \
        "#{(Time.current - chat_turn.last_activity_at).to_i / 60} minute(s)."
    end

    def activity_line
      if chat_turn.write_tool_dispatched?
        "A tool call that can have side effects was in progress when activity stopped. " \
          "Nothing has been marked as completed on your behalf."
      else
        "No tool with side effects had started running. The assistant's reply never finished."
      end
    end

    def guidance
      if automatic_recovery_attempted
        "An automatic recovery attempt is in progress."
      elsif chat_turn.recovery_exhausted?
        "Automatic and manual recovery attempts are exhausted for this turn. Send a new message to continue."
      else
        "Use Resume below to continue from where it left off, or send a new message instead."
      end
    end

    def metadata
      {
        "stalled_turn_notice" => true,
        "chat_turn_id" => chat_turn.id,
        "write_tool_dispatched" => chat_turn.write_tool_dispatched,
        "recovery_attempts" => chat_turn.recovery_attempts,
        "max_recovery_attempts" => ChatTurn::MAX_RECOVERY_ATTEMPTS,
        "automatic_recovery_attempted" => automatic_recovery_attempted,
        "recovery_exhausted" => chat_turn.recovery_exhausted?
      }
    end
  end
end
