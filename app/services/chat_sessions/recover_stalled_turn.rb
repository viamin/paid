# frozen_string_literal: true

module ChatSessions
  class RecoverStalledTurn
    class Conflict < ArgumentError; end
    class ConfirmationRequired < ArgumentError; end

    MAX_AUTOMATIC_RECOVERIES = 1

    def initialize(turn:, actor:, expected_revision:)
      @turn = turn
      @actor = actor
      @expected_revision = expected_revision
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-004 CHAT-TURN-005 CHAT-TURN-006 CHAT-TURN-007
    def call
      turn.with_lock do
        validate_claim!
        raise ConfirmationRequired, "Review tool activity before retrying this turn" unless turn.replay_safe?

        turn.update!(status: "pending", recovery_attempts: turn.recovery_attempts + 1,
          recovery_started_at: Time.current, last_activity_at: Time.current)
      end

      enqueue_recovery
      audit("enqueued")
      turn
    end

    private

    attr_reader :turn, :actor, :expected_revision

    def validate_claim!
      raise Conflict, "A turn revision is required" if expected_revision.blank?
      raise Conflict, "This turn has already changed" unless turn.lock_version == expected_revision.to_i
      raise Conflict, "This turn is not awaiting recovery" unless turn.status == "stalled"
      raise Conflict, "This turn has already been recovered" if turn.recovery_attempts >= MAX_AUTOMATIC_RECOVERIES
      raise Conflict, "You are not allowed to recover this turn" unless actor.account_id == turn.chat_session.account_id
    end

    def enqueue_recovery
      ChatSessions::ProcessMessageJob.perform_later(chat_session_id: turn.chat_session_id,
        content: turn.user_message.content, stream_message_id: turn.stream_message_id, actor_id: actor.id)
    end

    def audit(outcome)
      Rails.logger.info(message: "chat_turn.recovery", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
        outcome: outcome, recovery_attempts: turn.recovery_attempts, side_effecting_tools_completed: !turn.replay_safe?)
    end
  end
end
