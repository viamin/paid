# frozen_string_literal: true

class ChatMessagePolicy < ApplicationPolicy
  def index?
    chat_session_visible?
  end

  def create?
    return false unless user_in_account?
    # @spec QUESTION-EXPLORATION-001
    return false if chat_session.interactive_inbox_chat? && chat_session.closed?
    return chat_session_visible? if chat_session.interactive_inbox_chat?

    has_any_account_role?(:owner, :admin, :member)
  end

  def resolve?
    create?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(chat_session: ChatSessionPolicy::Scope.new(user, ChatSession).resolve)
    end
  end

  private

  def account_for_record
    record.respond_to?(:chat_session) ? record.chat_session.account : record.account
  end

  def chat_session
    record.chat_session
  end

  def chat_session_visible?
    ChatSessionPolicy.new(user, chat_session).show?
  end
end
