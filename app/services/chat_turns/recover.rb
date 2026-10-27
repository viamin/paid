# frozen_string_literal: true

module ChatTurns
  class Recover
    class UnsafeReplayError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(turn:, actor:)
      @turn = turn
      @actor = actor
    end

    def call
      turn.with_lock do
        raise UnsafeReplayError, "This turn cannot be retried because saved tool activity might be repeated." unless turn.stalled? && turn.safe_to_replay?

        turn.update!(state: "pending", recovery_requested_at: Time.current, recovery_attempts: turn.recovery_attempts + 1,
          last_activity_at: Time.current)
        ChatSessions::ProcessMessageJob.perform_later(chat_session_id: turn.chat_session_id, actor_id: actor.id,
          content: turn.user_message.content, stream_message_id: turn.stream_message_id)
      end
    end

    private

    attr_reader :turn, :actor
  end
end
