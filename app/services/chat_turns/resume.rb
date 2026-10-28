# frozen_string_literal: true

module ChatTurns
  # A user-authorized recovery. It never replays a completed side-effecting
  # tool: only turns whose durable transcript has no approved tool result can
  # be resumed, and the original user message remains the checkpoint.
  class Resume
    class UnsafeRecoveryError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(turn:, actor:)
      @turn = turn
      @actor = actor
    end

    def call
      deduplicated = @turn.with_lock do
        unless @turn.resumable?
          @turn.increment!(:duplicate_prevention_count)
          Rails.logger.info(message: "chat_turn.recovery_deduplicated", chat_turn_id: @turn.id,
            chat_session_id: @turn.chat_session_id, status: @turn.status)
          next true
        end

        @turn.update!(status: "streaming", recovery_started_at: Time.current,
          recovery_attempts: @turn.recovery_attempts + 1)
        @turn.record!("recovery_requested")
        ChatSessions::ProcessMessageJob.perform_later(
          chat_session_id: @turn.chat_session_id,
          actor_id: @actor.id,
          content: @turn.user_message.content,
          stream_message_id: @turn.metadata.fetch("stream_message_id")
        )
        false
      end
      raise UnsafeRecoveryError, "This turn is no longer available for recovery." if deduplicated
    end
  end
end
