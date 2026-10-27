# frozen_string_literal: true

module ChatSessions
  class ResumeTurnJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    # @spec CHAT-TURN-004 CHAT-TURN-005
    def perform(chat_turn_id:, actor_id:)
      turn = TenantContext.with_system_access { ChatTurn.find(chat_turn_id) }
      return unless turn.status == "streaming"

      TenantContext.with(turn.chat_session.account) do
        ChatSessions::ResumeTurn.call(chat_turn: turn, actor: turn.chat_session.account.users.find(actor_id))
      end
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => error
      record_failure(turn, error) if turn
    end

    private

    def record_failure(turn, error)
      turn.with_lock do
        return unless turn.status == "streaming"

        turn.transition_to!("failed", classification: "recovery_failed", data: { error_class: error.class.name })
        turn.chat_session.messages.create!(
          role: "system",
          content: "The requested recovery could not continue this response. No tool was replayed automatically; review the transcript and send a new message when ready.",
          metadata: { "chat_turn_recovery_failed_notice" => true, "chat_turn_id" => turn.id }
        )
      end
      Rails.logger.error(message: "chat_turn.recovery_failed", chat_turn_id: turn.id, error_class: error.class.name)
    end
  end
end
