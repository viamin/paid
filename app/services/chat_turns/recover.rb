# frozen_string_literal: true

module ChatTurns
  class RecoveryConfirmationRequired < StandardError; end
  class StaleRevision < StandardError; end

  class Recover
    # @spec CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-006
    def self.call(turn:, actor:, revision:, confirmed:, automatic: false)
      new(turn:, actor:, revision: revision.to_i, confirmed:, automatic:).call
    end

    def initialize(turn:, actor:, revision:, confirmed:, automatic:)
      @turn = turn
      @actor = actor
      @revision = revision
      @confirmed = confirmed
      @automatic = automatic
    end

    def call
      attempt, dispatch = locked_attempt
      enqueue(attempt) if dispatch
      attempt
    rescue ActiveRecord::RecordNotUnique
      record_duplicate
    end

    private

    attr_reader :turn, :actor, :revision, :confirmed, :automatic

    def locked_attempt
      turn.with_lock do
        turn.reload
        existing = turn.recovery_attempts.find_by(requested_revision: revision)
        return [ record_duplicate(existing), false ] if existing

        validate_recovery!
        attempt = turn.recovery_attempts.create!(actor:, automatic:, requested_revision: revision,
          status: "queued", deduplication_key: "#{turn.id}:#{revision}")
        turn.update!(state: "pending", last_activity_at: Time.current, recovery_outcome: nil)
        [ attempt, true ]
      end
    end

    def validate_recovery!
      raise StaleRevision, "Turn changed; reload before recovering it." unless turn.revision == revision
      raise ArgumentError, "Turn is not recoverable." unless turn.state.in?(%w[failed stalled])
      raise ArgumentError, "Automatic recovery is not replay-safe." if automatic && !turn.automatic_recovery_safe?
      return if automatic || confirmed

      raise RecoveryConfirmationRequired, "Review partial tool activity and confirm recovery."
    end

    def enqueue(attempt)
      ChatSessions::ProcessMessageJob.perform_later(
        chat_session_id: turn.chat_session_id,
        content: turn.user_message.content,
        stream_message_id: turn.stream_key,
        actor_id: actor.id,
        recovery_attempt_id: attempt.id
      )
      Rails.logger.warn(message: "chat_turn.recovery_dispatched", chat_turn_id: turn.id,
        recovery_attempt_id: attempt.id, automatic: automatic, requested_revision: revision)
    end

    def record_duplicate(existing = nil)
      turn.increment!(:duplicate_prevention_count)
      Rails.logger.info(message: "chat_turn.recovery_duplicate_prevented", chat_turn_id: turn.id,
        requested_revision: revision)
      existing || turn.recovery_attempts.find_by!(requested_revision: revision)
    end
  end
end
