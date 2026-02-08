# frozen_string_literal: true

# Represents a user's membership and role within an account.
#
# This replaces Rolify's polymorphic role system with an explicit join table
# that uses type-safe enums for roles.
#
# Roles are hierarchical (higher value = more permissions):
# - viewer (0): Read-only access to projects and runs
# - member (1): Add projects, run agents, view all account data
# - admin (2): Manage users, projects, settings; cannot delete account
# - owner (3): Full access, can delete account, manage billing
#
# @example Checking a user's role
#   membership = user.account_membership_for(account)
#   membership.admin? # => true/false
#
# @example Granting a role
#   AccountMembership.create!(user: user, account: account, role: :admin)
#
# @see ProjectMembership for project-level roles
# @see User#has_role? for checking roles
class AccountMembership < ApplicationRecord
  belongs_to :user
  belongs_to :account

  # Roles are ordered by permission level (higher = more permissions)
  enum :role, { viewer: 0, member: 1, admin: 2, owner: 3 }, validate: true

  validates :user_id, uniqueness: { scope: :account_id, message: "already has a membership in this account" }

  # Returns the permission level of this role (for comparison)
  def permission_level
    self.class.roles[role]
  end

  # Check if this membership has at least the given role level
  def at_least?(minimum_role)
    permission_level >= self.class.roles[minimum_role.to_s]
  end
end
