# frozen_string_literal: true

module ChatTurns
  # Recovers a stalled or abandoned chat turn. Recovery continues from the
  # durable checkpoint — the persisted transcript of the turn — instead of
  # replaying the whole request, and a replay guard makes sure a tool that
  # already completed inside the turn is never executed a second time.
  #
  # @spec CHAT-TURN-RECOVERY-010
  class Resume
    def self.call(turn:, actor: nil)
      new(turn:, actor:).call
    end

    def initialize(turn:, actor: nil)
      @turn = turn
      @actor = actor
    end

    def call
      transcript = ChatTurns::Transcript.call(turn)
      guard = ChatTurns::ReplayGuard.call(transcript: transcript)

      turn.reopen!
      turn.record_event(
        event_type: "recovery_started",
        outcome: "started",
        metadata: {
          classification: turn.classification,
          replay_safe: turn.replay_safe?,
          completed_tool_names: transcript.tool_names
        }
      )

      assistant_message = ChatSessions::SendMessage.call(
        chat_session: turn.chat_session,
        actor: actor || turn.chat_session.created_by,
        content: user_message.content.to_s,
        resume_user_message: user_message,
        replay_guard: guard,
        on_message_persisted: ->(message, stream_message_id: nil) { broadcast(message) }
      )

      finish_recovery(outcome: "completed")
      assistant_message
    rescue StandardError => error
      finish_recovery(outcome: "failed", error: error)
      raise
    end

    private

    attr_reader :turn, :actor

    def user_message
      turn.user_message
    end

    def finish_recovery(outcome:, error: nil)
      turn.finish_recovery!(outcome: outcome)
      turn.record_event(
        event_type: outcome == "completed" ? "recovery_completed" : "recovery_failed",
        outcome: outcome,
        metadata: { error: error&.message }.compact
      )
    end

    def broadcast(message)
      ChatSessions::BroadcastPersistedMessage.call(
        stream_name: "chat_session:#{turn.chat_session_id}",
        message: message
      )
    end
  end
end
