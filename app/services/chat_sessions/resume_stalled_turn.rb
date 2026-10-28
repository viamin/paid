# frozen_string_literal: true

module ChatSessions
  class ResumeStalledTurn
    include FallbackLoop

    class RecoveryConflictError < ArgumentError; end

    attr_reader :chat_turn, :chat_session, :actor, :llm_client, :on_chunk, :on_message_persisted, :stream_message_id,
      :transport_attempt_message

    def initialize(chat_turn:, actor:, llm_client: nil, on_chunk: nil, on_message_persisted: nil, stream_message_id: nil)
      @chat_turn = chat_turn
      @chat_session = chat_turn.chat_session
      @actor = actor
      @llm_client = llm_client
      @on_chunk = on_chunk
      @on_message_persisted = on_message_persisted
      @stream_message_id = stream_message_id
      @transport_attempt_message = chat_turn.user_message
    end

    def self.call(...)
      new(...).call
    end

    def call
      claim_recovery!
      assistant_message = run_with_fallbacks
      finish_recovery(assistant_message)
      assistant_message
    rescue AgentHarness::Error => error
      fail_recovery(error)
      raise
    end

    private

    def claim_recovery!
      deduplicated = chat_turn.with_lock do
        unless chat_turn.stalled?
          chat_turn.record!("recovery_deduplicated", state: chat_turn.state)
          next true
        end

        chat_turn.update!(state: "streaming", recovery_attempts: chat_turn.recovery_attempts + 1, last_activity_at: Time.current)
        chat_turn.record!("recovery_started", actor_id: actor.id)
        false
      end
      raise RecoveryConflictError, "Chat turn is not awaiting recovery" if deduplicated
    end

    def finish_recovery(assistant_message)
      if assistant_message
        chat_turn.update!(state: "completed", completed_at: Time.current, last_activity_at: Time.current)
        chat_turn.record!("recovery_completed", assistant_message_id: assistant_message.id)
      else
        chat_turn.update!(state: "pending", last_activity_at: Time.current)
        chat_turn.record!("recovery_awaiting_confirmation")
      end
    end

    def fail_recovery(error)
      return unless chat_turn.persisted?

      chat_turn.update!(state: "failed", failure_classification: error.class.name, last_activity_at: Time.current)
      chat_turn.record!("recovery_failed", error_class: error.class.name)
    end
  end
end
