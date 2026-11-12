# frozen_string_literal: true

# Mapping a Linear project to Paid project(s) is a bulk, account-wide change,
# so it is reserved to account owners/admins or a project_admin on every
# affected project.
#
# @spec UNIFIED-WORK-ITEMS-004
class WorkItemProjectMappingPolicy < ApplicationPolicy
  def create? = manage?
  def update? = manage?
  def destroy? = manage?

  def assign_to_projects?(projects)
    return false unless user_in_account?

    projects.all? { |project| has_any_account_role?(:owner, :admin) || user.has_role?(:project_admin, project) }
  end

  private

  def manage?
    has_any_account_role?(:owner, :admin)
  end
end
