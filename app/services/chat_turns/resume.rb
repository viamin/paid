# frozen_string_literal: true

module ChatTurns
  class Resume
    class ConflictError < ArgumentError; end

    def self.call(turn:, actor:)
      new(turn:, actor:).call
    end

    def initialize(turn:, actor:)
      @turn = turn
      @actor = actor
    end

    def call
      @turn.with_lock do
        raise ConflictError, "This turn is no longer stalled" unless @turn.status == "stalled"

        @turn.update!(status: "streaming", recovery_started_at: Time.current,
          recovery_attempts: @turn.recovery_attempts + 1, activity_at: Time.current)
      end
      ChatSessions::ProcessMessageJob.perform_later(chat_session_id: @turn.chat_session_id,
        actor_id: @actor.id, content: @turn.user_message.content, chat_turn_id: @turn.id,
        stream_message_id: SecureRandom.uuid)
      Rails.logger.info(message: "chat_turn.resume_requested", chat_turn_id: @turn.id,
        chat_session_id: @turn.chat_session_id, recovery_attempts: @turn.recovery_attempts)
    end
  end
end
