# frozen_string_literal: true

module ChatSessions
  class StallTurn
    def self.call(...)
      new(...).call
    end

    def initialize(turn:, threshold: ChatTurn::STALL_THRESHOLD.ago)
      @turn = turn
      @threshold = threshold
    end

    # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-002, CHAT-TURN-RECOVERY-003, CHAT-TURN-RECOVERY-004
    def call
      @turn.with_lock do
        return if @turn.terminal? || @turn.checkpointed_at >= @threshold || pending_confirmation? || rate_limited?

        @turn.update!(state: "stalled", classified_at: Time.current, terminal_at: Time.current)
        broadcast_notice(persist_notice)
      end
    end

    private

    def pending_confirmation?
      @turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def rate_limited?
      @turn.chat_session.rate_limited?
    end

    def persist_notice
      @turn.chat_session.messages.create!(
        role: "system",
        content: "This response stalled after its last saved activity. Any displayed tool results were preserved, but no assistant conclusion was recorded. Review the transcript and explicitly retry only after confirming that repeating unfinished work is safe.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => @turn.id }
      )
    end

    def broadcast_notice(message)
      ActionCable.server.broadcast("chat_session:#{@turn.chat_session_id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: message })
      })
    end
  end
end
