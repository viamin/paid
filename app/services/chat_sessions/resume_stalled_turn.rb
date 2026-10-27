# frozen_string_literal: true

module ChatSessions
  class ResumeStalledTurn
    class RecoveryConflictError < ArgumentError; end

    def self.call(chat_turn:, actor:)
      new(chat_turn:, actor:).call
    end

    def initialize(chat_turn:, actor:)
      @chat_turn = chat_turn
      @actor = actor
    end

    def call
      @chat_turn.with_lock do
        raise RecoveryConflictError, "Turn is not awaiting recovery" unless @chat_turn.status == "stalled"

        @chat_turn.update!(
          status: "streaming",
          recovery_attempts: @chat_turn.recovery_attempts + 1,
          last_activity_at: Time.current,
          metadata: @chat_turn.metadata.merge("last_recovery_actor_id" => @actor.id, "last_recovery_at" => Time.current.iso8601)
        )
      end

      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: @chat_turn.chat_session_id,
        actor_id: @actor.id,
        content: @chat_turn.initiating_message.content,
        stream_message_id: @chat_turn.initiating_message.metadata["stream_message_id"]
      )
    end
  end
end
