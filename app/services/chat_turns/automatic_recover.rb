# frozen_string_literal: true

module ChatTurns
  class AutomaticRecover
    MAX_ATTEMPTS = 1

    def self.call(...)
      new(...).call
    end

    def initialize(chat_session:, stream_message_id:, actor:)
      @chat_session = chat_session
      @stream_message_id = stream_message_id
      @actor = actor
    end

    def call
      turn = chat_session.chat_turns.joins(:user_message)
        .find_by(chat_messages: { metadata: { "stream_message_id" => stream_message_id } })
      return false unless turn

      turn.with_lock do
        turn.reload
        return deny(turn) unless safe_to_retry?(turn)

        turn.update!(status: "streaming", recovery_attempts: turn.recovery_attempts + 1,
          recovery_requested_by: actor, recovery_outcome: "automatic", last_activity_at: Time.current)
        turn.record_event!("automatic_recovery_started", actor: actor, classification: turn.failure_classification)
      end

      enqueue(turn)
      true
    end

    private

    attr_reader :chat_session, :stream_message_id, :actor

    def safe_to_retry?(turn)
      turn.status == "failed" && turn.failure_classification == "infrastructure" &&
        turn.recovery_attempts < MAX_ATTEMPTS && turn.messages.where(role: "tool").none?
    end

    def deny(turn)
      turn.record_event!("automatic_recovery_prevented", actor: actor,
        side_effecting_tools_completed: turn.side_effecting_tools_completed?)
      false
    end

    def enqueue(turn)
      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: turn.chat_session_id,
        actor_id: actor.id,
        content: turn.user_message.content,
        stream_message_id: stream_message_id
      )
    end
  end
end
