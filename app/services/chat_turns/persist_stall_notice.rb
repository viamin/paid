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
  end
end
