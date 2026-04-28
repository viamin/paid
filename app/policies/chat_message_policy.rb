# frozen_string_literal: true

class ChatMessagePolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:chat_session).where(chat_sessions: { account_id: user.account_id })
    end
  end

  private

  def account_for_record
    record.respond_to?(:chat_session) ? record.chat_session.account : record.account
  end
end
