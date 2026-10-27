# frozen_string_literal: true

class ChatTurns::RecoverTurnJob < ApplicationJob
  queue_as :default

  # @spec CHAT-TURN-LIFECYCLE-008 @spec CHAT-TURN-LIFECYCLE-011
  def perform(chat_turn_id:, actor_id:)
    TenantContext.with_system_access do
      turn = ChatTurn.find(chat_turn_id)
      return unless turn.recovery_state == "pending" && !turn.terminal?

      turn.update!(recovery_state: "in_progress")
      record(turn, "recovery_started")
      actor = turn.chat_session.account.users.find(actor_id)
      ChatSessions::SendMessage.call(chat_session: turn.chat_session, actor:, content: turn.user_message.content,
        stream_message_id: turn.user_message.metadata["stream_message_id"])
      turn.reload.update!(recovery_state: "succeeded")
      record(turn, "recovery_succeeded")
    rescue StandardError => error
      turn&.update!(recovery_state: "failed")
      record(turn, "recovery_failed", error_class: error.class.name) if turn
      raise
    end
  end

  private

  def record(turn, event_type, metadata: {})
    ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, account: turn.account, event_type:,
      classification: turn.classification, side_effecting_tools_completed: turn.side_effecting_tools_completed, metadata:)
  end
end
