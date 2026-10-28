# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-API-029
  class Resume
    class ConflictError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(turn:, actor:, expected_revision:)
      @turn = turn
      @actor = actor
      @expected_revision = Integer(expected_revision)
    end

    def call
      claim!
      enqueue!
      turn.reload
    end

    private

    attr_reader :turn, :actor, :expected_revision

    def claim!
      rows = ChatTurn.where(id: turn.id, status: "stalled", lock_version: expected_revision)
        .update_all(
          status: "pending",
          recovered_by_id: actor.id,
          recovery_attempts: turn.recovery_attempts + 1,
          recovery_outcome: "queued",
          lock_version: expected_revision + 1,
          updated_at: Time.current
        )
      raise ConflictError, "This turn was already recovered or changed" if rows.zero?
    end

    def enqueue!
      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: turn.chat_session_id,
        actor_id: actor.id,
        content: turn.user_message.content,
        stream_message_id: turn.stream_id,
        recovery: true
      )
    end
  end
end
