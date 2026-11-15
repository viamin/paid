# frozen_string_literal: true

# Individual assignment follows the same permission tier as running an agent
# or managing issues on the target project. Customize/replace overrides,
# issue-level execution defaults, and review-flag resolution are reserved to
# project automation owners because they steer future automation.
#
# @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-005
class WorkItemPolicy < ApplicationPolicy
  def assign_to_project?(project)
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member) || user.has_any_role?(:project_admin, :project_member, project)
  end

  def override?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin) || record.projects.any? { |project| user.has_role?(:project_admin, project) }
  end

  # Resolving a mapping/native-project change that flagged an existing
  # override is a human review act owned by project automation owners.
  def review?
    override?
  end
end
