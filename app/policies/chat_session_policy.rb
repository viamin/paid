# frozen_string_literal: true

class ChatSessionPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    return false unless user_in_account?
    return inbox_chat_access? if record.interactive_inbox_chat?

    linked_chat_visible?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    return inbox_chat_access? if record.interactive_inbox_chat?

    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def reopen?
    linked_chat_visible? && create?
  end

  def destroy?
    return inbox_chat_access? if record.interactive_inbox_chat?

    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def archive?
    return inbox_chat_access? if record.interactive_inbox_chat?

    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def unarchive?
    return false if record.interactive_inbox_chat?

    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      sessions = scope.where(account_id: user.account_id)
      return sessions if account_operator?

      visible_regular_sessions(sessions).or(personal_inbox_chats(sessions))
    end

    private

    def visible_regular_sessions(sessions)
      visible_ids = scope.left_outer_joins(project: :project_memberships)
        .where(account: user.account, inbox_item_key: nil)
        .where("chat_sessions.clarifying_question_issue_id IS NULL OR project_memberships.user_id = ?", user.id)
        .select(:id)

      sessions.where(id: visible_ids)
    end

    def personal_inbox_chats(sessions)
      inbox_chats = sessions.where.not(inbox_item_key: nil).where(created_by: user)
      return inbox_chats if user.has_any_role?(:member, user.account)

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

    def account_operator?
      user.has_any_role?(:owner, :admin, user.account)
    end
  end

  private

  def inbox_chat_access?
    record.created_by == user && Inbox::InteractiveChatAccess.allowed?(user:, project: record.project)
  end

  def linked_chat_visible?
    return user_in_account? unless record.clarifying_question_issue.present?

    ProjectPolicy.new(user, record.project).explore?
  end
end
