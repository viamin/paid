# frozen_string_literal: true

module ChatTurns
  # @spec CHAT-TURN-LIFECYCLE-007 @spec CHAT-TURN-LIFECYCLE-009
  class RequestRecovery
    StaleTurnError = Class.new(StandardError)
    ConfirmationRequiredError = Class.new(StandardError)

    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:, actor:, confirmed: false)
      @chat_turn = chat_turn
      @actor = actor
      @confirmed = confirmed
    end

    def call
      raise StaleTurnError, "This turn already has a terminal outcome" if chat_turn.terminal?
      raise StaleTurnError, "This turn has exhausted its recovery attempts" if chat_turn.recovery_budget_exhausted?
      raise ConfirmationRequiredError, "Confirm recovery before continuing this turn" if confirmation_required?

      claim_or_record_duplicate
    end

    private

    attr_reader :chat_turn, :actor, :confirmed

    def confirmation_required?
      !confirmed && (chat_turn.confirmation_required_classification? || chat_turn.side_effecting_tools_completed)
    end

    def claim_or_record_duplicate
      unless chat_turn.claim_recovery!(to: "pending")
        record("duplicate_recovery_prevented")
        return false
      end

      chat_turn.update!(recovery_attempts: chat_turn.recovery_attempts + 1, recovery_requested_by_id: actor.id,
        recovery_requested_at: Time.current)
      record("recovery_requested", user_action: "resume")
      ChatTurns::RecoverTurnJob.perform_later(chat_turn_id: chat_turn.id, actor_id: actor.id)
      true
    end

    def record(event_type, user_action: nil)
      ChatTurnEvent.create!(chat_turn: chat_turn, chat_session: chat_turn.chat_session, account: chat_turn.account,
        event_type:, user_action:, classification: chat_turn.classification,
        side_effecting_tools_completed: chat_turn.side_effecting_tools_completed)
    end
  end
end
