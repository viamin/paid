# frozen_string_literal: true

module ChatTurns
  # Requests recovery of a stalled or abandoned chat turn.
  #
  # Recovery is deduplicated: the turn carries a single recovery slot and the
  # request claims it with a compare-and-swap, so concurrent or repeated
  # requests cannot start a second attempt. Automatic recovery is opt-in per
  # failure classification — only a turn that produced no output and ran no
  # side-effecting tool is replayed unattended; everything else waits for the
  # user's confirmation.
  #
  # @spec CHAT-TURN-RECOVERY-008 @spec CHAT-TURN-RECOVERY-009 @spec CHAT-TURN-RECOVERY-011
  class RequestRecovery
    Result = Data.define(:status, :turn, :reason)

    STARTED = "started"
    DUPLICATE = "duplicate"
    NOT_RECOVERABLE = "not_recoverable"
    CONFIRMATION_REQUIRED = "confirmation_required"
    EXHAUSTED = "exhausted"

    def self.call(turn:, source:, actor: nil)
      new(turn:, source:, actor:).call
    end

    def initialize(turn:, source:, actor: nil)
      @turn = turn
      @source = source
      @actor = actor
    end

    def call
      return result(NOT_RECOVERABLE, "the turn has no stalled state to recover") unless turn.recoverable?
      return result(CONFIRMATION_REQUIRED, "this turn needs an explicit confirmation to recover") unless recovery_allowed?
      return result(EXHAUSTED, "the turn already used its recovery budget") if turn.recovery_attempts_exhausted?

      unless turn.claim_recovery!
        record_duplicate_prevented
        return result(DUPLICATE, "a recovery attempt is already running for this turn")
      end

      record_requested
      ChatTurns::RecoverTurnJob.perform_later(chat_turn_id: turn.id, actor_id: actor&.id)
      result(STARTED, "recovery started")
    end

    private

    attr_reader :turn, :source, :actor

    def result(status, reason)
      Result.new(status:, turn:, reason:)
    end

    # An automatic recovery is only allowed for a classification whose replay is
    # safe. A user-requested recovery is the explicit confirmation the stalled
    # notice asks for.
    def recovery_allowed?
      return true unless source == :automatic

      turn.automatic_recovery_eligible?
    end

    def record_requested
      turn.record_event(
        event_type: "recovery_requested",
        outcome: source.to_s,
        actor: actor,
        metadata: {
          classification: turn.classification,
          replay_safe: turn.replay_safe?,
          side_effecting_tools_completed: turn.side_effecting_tools_completed,
          revision: turn.revision
        }
      )
    end

    # @spec CHAT-TURN-RECOVERY-011
    def record_duplicate_prevented
      turn.record_event(
        event_type: "duplicate_prevented",
        outcome: source.to_s,
        actor: actor,
        metadata: { recovery_attempts: turn.recovery_attempts, recovery_state: turn.recovery_state }
      )
      Rails.logger.info(
        message: "chat_turns.recovery.duplicate_prevented",
        chat_turn_id: turn.id,
        chat_session_id: turn.chat_session_id,
        source: source.to_s,
        recovery_attempts: turn.recovery_attempts
      )
    end
  end
end
