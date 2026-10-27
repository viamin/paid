# frozen_string_literal: true

module ChatTurns
  class Recover
    def self.call(...)
      new(...).call
    end

    def initialize(turn:, actor:, expected_lock_version:)
      @turn = turn
      @actor = actor
      @expected_lock_version = expected_lock_version.to_i
    end

    def call
      return false unless turn.claim_recovery!(actor: actor, expected_lock_version: expected_lock_version)

      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: turn.chat_session_id,
        actor_id: actor.id,
        content: turn.user_message.content,
        stream_message_id: turn.checkpoint.fetch("stream_message_id", SecureRandom.uuid)
      )
      true
    end

    private

    attr_reader :turn, :actor, :expected_lock_version
  end
end
