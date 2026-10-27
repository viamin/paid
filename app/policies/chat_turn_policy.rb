# frozen_string_literal: true

class ChatTurnPolicy < ApplicationPolicy
  def show?
    ChatSessionPolicy.new(user, record.chat_session).show?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      session_ids = ChatSessionPolicy::Scope.new(user, ChatSession).resolve.select(:id)
      scope.where(chat_session_id: session_ids)
    end
  end
end
