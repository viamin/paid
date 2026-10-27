# frozen_string_literal: true

class ChatSessions::RecoverStalledTurnJob < ApplicationJob
  queue_as :default

  # @spec CHAT-TURN-RECOVERY-004
  def perform(chat_turn_id:)
    turn = ChatTurn.find(chat_turn_id)
    turn.with_lock do
      return unless turn.status == "stalled" && turn.replay_safe? && turn.recovery_token.present?

      turn.transition!("streaming")
      ChatSessions::ProcessMessageJob.perform_later(chat_session_id: turn.chat_session_id,
        actor_id: turn.actor_id, content: turn.user_message.content, stream_message_id: turn.stream_message_id)
    end
  end

  def tenant_account
    TenantContext.with_system_access { ChatTurn.find_by(id: arguments.first[:chat_turn_id])&.chat_session&.account }
  end
end
