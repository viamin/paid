# frozen_string_literal: true

class ChatTurnPolicy < ApplicationPolicy
  def resume?
    ChatMessagePolicy.new(user, ChatMessage.new(chat_session: record.chat_session)).create?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:chat_session).where(chat_sessions: { account_id: user.account_id })
    end
  end
end
