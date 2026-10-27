# frozen_string_literal: true

module ChatSessions
  class RecoverStalledTurn
    class RecoveryConflictError < ArgumentError; end
    class UnsafeRecoveryError < ArgumentError; end

    attr_reader :turn

    def initialize(turn:)
      @turn = turn
    end

    def self.call(...)
      new(...).call
    end

    # @spec CHAT-TURN-RECOVERY-003
    def call
      turn.with_lock do
        raise RecoveryConflictError, "Chat turn is not awaiting recovery" unless turn.reload.stalled?
        raise UnsafeRecoveryError, "This turn used a completed write tool and cannot be replayed" if completed_write_tool?

        turn.update!(status: "pending", activity_at: Time.current, recovery_attempts: turn.recovery_attempts + 1,
          metadata: turn.metadata.merge("recovery_outcome" => "enqueued"))
        ChatSessions::ProcessMessageJob.perform_later(
          chat_session_id: turn.chat_session_id,
          content: turn.user_message.content,
          stream_message_id: turn.stream_message_id
        )
        Rails.logger.info(message: "chat_turn.recovery_enqueued", chat_turn_id: turn.id, recovery_attempts: turn.recovery_attempts)
      end
    end

    private

    def completed_write_tool?
      turn.chat_session.messages.where("id > ?", turn.user_message_id).where.not(tool_result: nil)
        .any? { |message| Tools::Registry.write_tool?(message.tool_name) }
    end
  end
end
