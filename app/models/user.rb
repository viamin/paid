# frozen_string_literal: true

class User < ApplicationRecord
  belongs_to :account
  has_many :account_memberships, dependent: :destroy
  has_many :member_accounts, through: :account_memberships, source: :account
  has_many :project_memberships, dependent: :destroy
  has_many :member_projects, through: :project_memberships, source: :project
  has_many :created_github_tokens, class_name: "GithubToken", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by
  has_many :created_projects, class_name: "Project", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  validates :account, presence: true

  after_create :assign_owner_role_if_first_user

  # Role Management API
  # These methods provide a compatible interface with the previous Rolify implementation

  # Check if user has a specific role on a resource
  #
  # @param role [Symbol, String] The role to check (e.g., :admin, :owner)
  # @param resource [Account, Project] The resource to check the role on
  # @return [Boolean] true if user has the exact role
  #
  # @example
  #   user.has_role?(:admin, account) # => true/false
  #   user.has_role?(:project_admin, project) # => true/false
  def has_role?(role, resource)
    membership = membership_for(resource)
    return false unless membership

    normalize_role(role, resource) == membership.role
  end

  # Check if user has any of the specified roles on a resource
  #
  # @param roles [Array<Symbol, String>] The roles to check
  # @param resource [Account, Project] The resource to check roles on
  # @return [Boolean] true if user has any of the roles
  #
  # @example
  #   user.has_any_role?(:owner, :admin, account) # => true/false
  def has_any_role?(*args)
    resource = args.pop
    roles = args

    membership = membership_for(resource)
    return false unless membership

    roles.any? { |role| normalize_role(role, resource) == membership.role }
  end

  # Add a role to user on a resource
  #
  # @param role [Symbol, String] The role to add (e.g., :admin, :owner)
  # @param resource [Account, Project] The resource to add the role on
  # @return [AccountMembership, ProjectMembership] The created or updated membership
  #
  # @example
  #   user.add_role(:admin, account)
  #   user.add_role(:project_member, project)
  def add_role(role, resource)
    normalized_role = normalize_role(role, resource)

    case resource
    when Account
      account_memberships.find_or_initialize_by(account: resource).tap do |m|
        m.role = normalized_role
        m.save!
      end
    when Project
      project_memberships.find_or_initialize_by(project: resource).tap do |m|
        m.role = normalized_role
        m.save!
      end
    else
      raise ArgumentError, "Unknown resource type: #{resource.class}"
    end
  end

  # Remove a role from user on a resource
  #
  # @param role [Symbol, String] The role to remove
  # @param resource [Account, Project] The resource to remove the role from
  # @return [Boolean] true if role was removed
  def remove_role(role, resource)
    membership = membership_for(resource)
    return false unless membership
    return false unless normalize_role(role, resource) == membership.role

    membership.destroy
    true
  end

  # Get the user's role on a resource
  #
  # @param resource [Account, Project] The resource to check
  # @return [String, nil] The role name or nil if no membership
  def role_on(resource)
    membership_for(resource)&.role
  end

  # Get the membership record for a resource
  #
  # @param resource [Account, Project] The resource
  # @return [AccountMembership, ProjectMembership, nil] The membership or nil
  def membership_for(resource)
    case resource
    when Account
      account_memberships.find_by(account: resource)
    when Project
      project_memberships.find_by(project: resource)
    end
  end

  # Convenience method for getting account membership
  def account_membership_for(account)
    account_memberships.find_by(account: account)
  end

  # Convenience method for getting project membership
  def project_membership_for(project)
    project_memberships.find_by(project: project)
  end

  private

  def assign_owner_role_if_first_user
    return unless account.users.count == 1

    add_role(:owner, account)
  end

  # Normalize role names between old Rolify format and new enum format
  # Old format: :project_admin, :project_member, :project_viewer
  # New format: :admin, :member, :viewer (on ProjectMembership)
  def normalize_role(role, resource)
    role_str = role.to_s

    case resource
    when Project
      # Convert project_* roles to simple roles
      role_str.sub(/^project_/, "")
    else
      role_str
    end
  end
end
