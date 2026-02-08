# frozen_string_literal: true

class ProjectPolicy < ApplicationPolicy
  # Inherits from ApplicationPolicy:
  # - index?, show?: user_in_account?
  # - create?, new?: owner/admin/member
  # - update?, edit?: owner/admin
  # - destroy?: owner only
  #
  # Project-specific permissions:
  # - run_agent?: can trigger agent runs (members + project roles)

  def run_agent?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member) || has_project_role?
  end

  private

  def has_project_role?
    return false unless user && record.is_a?(Project)

    user.has_any_role?(:project_admin, :project_member, record)
  end
end
