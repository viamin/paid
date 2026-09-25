# frozen_string_literal: true

class ChatSessionPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    linked_chat_visible?
  end

  def create?
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def reopen?
    linked_chat_visible? && create?
  end

  def destroy?
    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def archive?
    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  def unarchive?
    linked_chat_visible? && has_any_account_role?(:owner, :admin, :member)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user
      return scope.where(account: user.account) if account_operator?

      scope.left_outer_joins(project: :project_memberships)
        .where(account: user.account)
        .where("chat_sessions.clarifying_question_issue_id IS NULL OR project_memberships.user_id = ?", user.id)
        .distinct
    end

    private

    def account_operator?
      user.has_any_role?(:owner, :admin, user.account)
    end
  end

  private

  def linked_chat_visible?
    return user_in_account? unless record.clarifying_question_issue.present?

    ProjectPolicy.new(user, record.project).explore?
  end
end
