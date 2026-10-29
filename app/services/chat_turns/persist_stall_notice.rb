# frozen_string_literal: true

module ChatTurns
  # Persists the in-transcript system notice for a newly stalled turn (#4680).
  # Separate from broadcasting it: callers that run outside a request/channel
  # context (ChatTurns::StallDetectorJob) broadcast the returned message
  # themselves, mirroring ChatSessions::MarkRateLimited.
  class PersistStallNotice
    def self.call(chat_turn:, automatic_recovery_attempted:)
      built = StalledTurnNoticeMessage.build(
        chat_turn: chat_turn,
        automatic_recovery_attempted: automatic_recovery_attempted
      )
      chat_turn.chat_session.messages.create!(role: "system", content: built.content, metadata: built.metadata)
    end

    def self.refresh_after_recovery_failure!(chat_turn:)
      refresh!(chat_turn: chat_turn)
    end

    def self.refresh_after_recovery_success!(chat_turn:)
      refresh!(chat_turn: chat_turn)
    end

    private_class_method def self.refresh!(chat_turn:)
      notice = latest_notice(chat_turn)
      return unless notice

      built = StalledTurnNoticeMessage.build(chat_turn: chat_turn, automatic_recovery_attempted: false)
      notice.update!(content: built.content, metadata: built.metadata)
      notice
    end

    private_class_method def self.latest_notice(chat_turn)
      chat_turn.chat_session.messages
        .where("metadata @> ?", { stalled_turn_notice: true, chat_turn_id: chat_turn.id }.to_json)
        .order(id: :desc)
        .first
    end
  end
end
