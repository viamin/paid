# frozen_string_literal: true

# @spec TENANT-ACCESS-001
# @spec TENANT-ACCESS-002
class ProjectPolicy < ApplicationPolicy
  # Inherits from ApplicationPolicy:
  # - index?, show?: user_in_account?
  # - create?, new?: owner/admin/member
  # - update?, edit?: owner/admin
  # - destroy?: owner only
  #
  # Project-specific permissions:
  # - run_agent?: can trigger agent runs (members + project roles)
  # - manage_issues?: can file and update GitHub issues via MCP tools
  # - manage_apple_verifications?: can approve workflows and waive attempts

  def run_agent?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member) || has_project_role?
  end

  def manage_issues?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member) || has_project_role?
  end

  # @spec APPLE-VERIFY-002
  # @spec APPLE-VERIFY-003
  def manage_apple_verifications?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin) || user.has_role?(:project_admin, record)
  end

  private

  def has_project_role?
    return false unless user && record.is_a?(Project)

    user.has_any_role?(:project_admin, :project_member, record)
  end
end
