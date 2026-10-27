# frozen_string_literal: true

module ChatTurns
  class RecoveryConflictError < ArgumentError; end

  class RequestRecovery
    MAX_RECOVERY_ATTEMPTS = 1

    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:, actor:)
      @chat_turn = chat_turn
      @actor = actor
    end

    def call
      duplicate_message = chat_turn.with_lock do
        next "This turn is no longer awaiting recovery" unless chat_turn.status == "stalled"
        next "This turn has already used its safe recovery attempt" if chat_turn.recovery_attempts >= MAX_RECOVERY_ATTEMPTS

        chat_turn.update!(status: "streaming", recovery_attempts: chat_turn.recovery_attempts + 1,
          recovery_requested_at: Time.current, last_activity_at: Time.current)
        chat_turn.events.create!(event_type: "recovery_requested", data: { actor_id: actor.id })
        nil
      end
      reject_duplicate!(duplicate_message) if duplicate_message
      ChatSessions::ResumeTurnJob.perform_later(chat_turn_id: chat_turn.id, actor_id: actor.id)
      chat_turn
    end

    private

    attr_reader :chat_turn, :actor

    def reject_duplicate!(message)
      chat_turn.events.create!(event_type: "recovery_deduplicated", data: { actor_id: actor.id })
      raise RecoveryConflictError, message
    end
  end
end
