# frozen_string_literal: true

class ChatTurnPolicy < ApplicationPolicy
  # Recovering a stalled turn continues the conversation, so it needs the same
  # authorization as sending a message in that conversation.
  # @spec CHAT-TURN-RECOVERY-012
  def recover?
    return false unless user
    return false unless record.chat_session.account_id == user.account_id

    ChatMessagePolicy.new(user, ChatMessage.new(chat_session: record.chat_session)).create?
  end
end
