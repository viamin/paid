# frozen_string_literal: true

module ChatTurns
  class Resume
    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:, actor:, expected_revision:)
      @chat_turn = chat_turn
      @actor = actor
      @expected_revision = Integer(expected_revision)
    end

    # @spec CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-006 CHAT-TURN-RECOVERY-007
    def call
      attempt, enqueue = claim_attempt
      enqueue_recovery(attempt) if enqueue
      attempt
    end

    private

    attr_reader :chat_turn, :actor, :expected_revision

    def claim_attempt
      chat_turn.with_lock do
        existing = chat_turn.recovery_attempts.find_by(source_revision: expected_revision)
        return [ record_duplicate(existing), false ] if existing

        validate_revision!
        attempt = create_attempt
        chat_turn.update!(status: "pending", classification: nil, pause_reason: nil,
          detected_stalled_at: nil, last_activity_at: Time.current)
        [ attempt, true ]
      end
    end

    def validate_revision!
      raise ActiveRecord::StaleObjectError.new(chat_turn, "resume") unless chat_turn.lock_version == expected_revision
      raise ArgumentError, "Only stalled turns can be resumed" unless chat_turn.status == "stalled"
      raise ArgumentError, "The original user message is unavailable" unless chat_turn.user_message
    end

    def create_attempt
      chat_turn.recovery_attempts.create!(account: chat_turn.account, requested_by: actor,
        source_revision: expected_revision)
    end

    def record_duplicate(attempt)
      attempt.increment!(:duplicate_prevention_count)
      Rails.logger.info(message: "chat_turn.recovery_deduplicated", chat_session_id: chat_turn.chat_session_id,
        chat_turn_id: chat_turn.id, recovery_attempt_id: attempt.id)
      attempt
    end

    def enqueue_recovery(attempt)
      ChatSessions::ProcessMessageJob.perform_later(chat_session_id: chat_turn.chat_session_id,
        content: chat_turn.user_message.content, stream_message_id: chat_turn.stream_message_id,
        actor_id: actor.id, chat_turn_id: chat_turn.id, recovery_attempt_id: attempt.id)
      Rails.logger.info(message: "chat_turn.recovery_requested", chat_session_id: chat_turn.chat_session_id,
        chat_turn_id: chat_turn.id, recovery_attempt_id: attempt.id)
    end
  end
end
