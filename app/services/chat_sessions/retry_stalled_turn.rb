# frozen_string_literal: true

module ChatSessions
  class RetryStalledTurn
    def self.call(...) = new(...).call

    def initialize(chat_turn:, actor:, lock_version:)
      @chat_turn = chat_turn
      @actor = actor
      @lock_version = lock_version.to_i
    end

    # @spec CHAT-TURN-RECOVERY-004
    def call
      @chat_turn.with_lock do
        raise ActiveRecord::StaleObjectError.new(@chat_turn, "retry") unless @chat_turn.lock_version == @lock_version
        raise ArgumentError, "chat turn is not stalled" unless @chat_turn.status == "stalled"

        @chat_turn.update!(status: "pending", recovery_attempts: @chat_turn.recovery_attempts + 1, last_activity_at: Time.current)
        @chat_turn.events.create!(event_type: "recovery_requested", metadata: { "actor_id" => @actor.id })
        ChatSessions::ProcessMessageJob.perform_later(
          chat_session_id: @chat_turn.chat_session_id,
          actor_id: @actor.id,
          content: @chat_turn.user_message.content,
          stream_message_id: @chat_turn.stream_message_id
        )
      end
    end
  end
end
