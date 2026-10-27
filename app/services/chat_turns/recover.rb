# frozen_string_literal: true

module ChatTurns
  class Recover
    class NotRecoverable < StandardError; end

    def self.call(turn:, actor:)
      new(turn:, actor:).call
    end

    def initialize(turn:, actor:)
      @turn = turn
      @actor = actor
    end

    def call
      claim_recovery!
      ChatSessions::SendMessage.call(chat_session: @turn.chat_session, actor: @actor,
        content: @turn.user_message.content, user_message: @turn.user_message)
    end

    private

    def claim_recovery!
      @turn.with_lock do
        @turn.reload
        raise NotRecoverable, "This turn is already being recovered or is no longer stalled." unless @turn.state == "stalled"

        @turn.update!(state: "streaming", recovery_started_at: Time.current,
          recovery_attempts: @turn.recovery_attempts + 1, activity_at: Time.current)
      end
    end
  end
end
