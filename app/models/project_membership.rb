# frozen_string_literal: true

# Represents a user's membership and role within a specific project.
#
# This provides project-level access control independent of account roles.
# A user can have different roles on different projects within the same account.
#
# Roles are hierarchical (higher value = more permissions):
# - viewer (0): Read-only access to project data
# - member (1): Run agents, view project data
# - admin (2): Full control over the project
#
# @example Granting project access
#   ProjectMembership.create!(user: user, project: project, role: :member)
#
# @example Checking project access
#   membership = user.project_membership_for(project)
#   membership&.admin? # => true/false/nil
#
# @see AccountMembership for account-level roles
# @see User#has_role? for checking roles
class ProjectMembership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  # Roles are ordered by permission level (higher = more permissions)
  enum :role, { viewer: 0, member: 1, admin: 2 }, validate: true

  validates :user_id, uniqueness: { scope: :project_id, message: "already has a membership in this project" }

  # Returns the permission level of this role (for comparison)
  def permission_level
    self.class.roles[role]
  end

  # Check if this membership has at least the given role level
  def at_least?(minimum_role)
    permission_level >= self.class.roles[minimum_role.to_s]
  end
end
