# frozen_string_literal: true

class ChatSessionPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    return false unless user_in_account?
    return true unless record.interactive_inbox_chat?

    inbox_chat_access?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    return inbox_chat_access? if record.interactive_inbox_chat?

    has_any_account_role?(:owner, :admin, :member)
  end

  def reopen?
    create?
  end

  def destroy?
    has_any_account_role?(:owner, :admin, :member)
  end

  def archive?
    update?
  end

  def unarchive?
    update?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      sessions = scope.where(account_id: user.account_id)
      return sessions if user.has_any_role?(:owner, :admin, :member, user.account)

      sessions.where(<<~SQL.squish, user.id, user.id)
        chat_sessions.inbox_item_key IS NULL OR (
          chat_sessions.created_by_id = ? AND EXISTS (
            SELECT 1 FROM project_memberships
            WHERE project_memberships.project_id = chat_sessions.project_id
              AND project_memberships.user_id = ?
              AND project_memberships.role IN ('member', 'admin')
          )
        )
      SQL
    end
  end

  private

  def inbox_chat_access?
    record.created_by == user && Inbox::InteractiveChatAccess.allowed?(user:, project: record.project)
  end
end
