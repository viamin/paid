# frozen_string_literal: true

class ChatMessagePolicy < ApplicationPolicy
  def index?
    chat_session_visible?
  end

  def create?
    chat_session_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def resolve?
    create?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:chat_session).merge(ChatSessionPolicy::Scope.new(user, ChatSession).resolve)
    end
  end

  private

  def account_for_record
    record.respond_to?(:chat_session) ? record.chat_session.account : record.account
  end

  def chat_session_visible?
    ChatSessionPolicy.new(user, record.chat_session).show?
  end
end
