# frozen_string_literal: true

# Individual assignment follows the same permission tier as running an agent
# or managing issues on the target project. Customize/replace overrides are
# reserved to project automation owners because they lock the item against
# future mapping changes.
#
# @spec UNIFIED-WORK-ITEMS-004
class WorkItemPolicy < ApplicationPolicy
  def assign_to_project?(project)
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member) || user.has_any_role?(:project_admin, :project_member, project)
  end

  def override?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin) || record.projects.any? { |project| user.has_role?(:project_admin, project) }
  end
end
