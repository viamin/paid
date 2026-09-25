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
    return inbox_chat_access? if record.interactive_inbox_chat?

    has_any_account_role?(:owner, :admin, :member)
  end

  def archive?
    update?
  end

  def unarchive?
    return false if record.interactive_inbox_chat?

    update?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      sessions = scope.where(account_id: user.account_id)
      return regular_sessions_or_personal_inbox_chats(sessions) if user.has_any_role?(:owner, :admin, :member, user.account)

      personal_inbox_chats(sessions)
    end

    private

    def regular_sessions_or_personal_inbox_chats(sessions)
      sessions.where(inbox_item_key: nil).or(personal_inbox_chats(sessions))
    end

    def personal_inbox_chats(sessions)
      inbox_chats = sessions.where.not(inbox_item_key: nil).where(created_by: user)
      return inbox_chats if account_comment_authority?

      inbox_chats.where(<<~SQL.squish, user.id, comment_authority_roles)
        EXISTS (
          SELECT 1 FROM project_memberships
          WHERE project_memberships.project_id = chat_sessions.project_id
            AND project_memberships.user_id = ?
            AND project_memberships.role IN (?)
        )
      SQL
    end

    def comment_authority_roles
      ProjectMembership.roles.values_at("member", "admin")
    end

    def account_comment_authority?
      user.has_any_role?(:owner, :admin, :member, user.account)
    end
  end

  private

  def inbox_chat_access?
    record.created_by == user && Inbox::InteractiveChatAccess.allowed?(user:, project: record.project)
  end
end
