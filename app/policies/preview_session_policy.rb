# frozen_string_literal: true

class PreviewSessionPolicy < ApplicationPolicy
  # Preview access must stay project-scoped: account owners/admins may see all
  # project previews in the account, but account-level members need an explicit
  # project role on the session's project.
  def show?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin) || has_project_role?
  end

  def stop?
    ProjectPolicy.new(user, record.project).update?
  end

  private

  def has_project_role?
    user.has_any_role?(:project_admin, :project_member, record.project)
  end

  def account_for_record
    record.project.account
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      if user.has_any_role?(:owner, :admin, user.account)
        scope.joins(:project).where(projects: { account_id: user.account_id })
      else
        scope.joins(project: :project_memberships)
          .where(projects: { account_id: user.account_id })
          .where(project_memberships: { user_id: user.id })
          .distinct
      end
    end
  end
end
