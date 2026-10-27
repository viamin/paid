# frozen_string_literal: true

class ChatSessions::RecoverStalledTurnJob < ApplicationJob
  queue_as :default

  # @spec CHAT-TURN-RECOVERY-007
  def perform(chat_turn_id:, actor_id: nil)
    turn = nil
    actor = nil
    turn = ChatTurn.find(chat_turn_id)
    actor = turn.chat_session.account.users.find(actor_id || turn.chat_session.created_by_id)
    TenantContext.with(turn.chat_session.account) do
      ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, actor:, event_type: "recovery_started", outcome: "started",
        side_effecting_tools_completed: turn.side_effecting_tools_completed?)
      ChatSessions::SendMessage.call(chat_session: turn.chat_session, actor:, content: turn.user_message.content,
        user_message: turn.user_message, force_manual_confirmation: true)
      turn.reload.update!(recovery_state: "succeeded")
      ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, actor:, event_type: "recovery_succeeded", outcome: "completed",
        side_effecting_tools_completed: turn.side_effecting_tools_completed?)
    end
  rescue StandardError => error
    turn&.update!(recovery_state: "failed")
    ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, actor:, event_type: "recovery_failed", outcome: error.class.name,
      side_effecting_tools_completed: turn.side_effecting_tools_completed?) if turn
    raise
  end
end
