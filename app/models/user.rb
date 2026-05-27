# frozen_string_literal: true

class User < ApplicationRecord
  has_logidze
  belongs_to :account
  has_many :account_memberships, dependent: :destroy
  has_many :member_accounts, through: :account_memberships, source: :account
  has_many :project_memberships, dependent: :destroy
  has_many :member_projects, through: :project_memberships, source: :project
  has_many :issue_merge_subscriptions, dependent: :destroy
  has_many :created_github_tokens, class_name: "GithubToken", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by
  has_many :created_integration_credentials, class_name: "IntegrationCredential", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by
  has_many :created_projects, class_name: "Project", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by
  has_one :user_setting, dependent: :destroy
  has_many :runner_states, dependent: :destroy
  has_many :provider_states, class_name: "ProviderState", dependent: :destroy
  has_many :runners, dependent: :destroy
  has_many :providers, class_name: "Provider", dependent: :destroy
  has_many :provider_api_keys, dependent: :destroy
  has_many :account_activity_events, foreign_key: :actor_id, dependent: :nullify, inverse_of: :actor
  has_many :pre_commit_requirements, dependent: :destroy
  has_many :initiated_agent_runs, class_name: "AgentRun", foreign_key: :initiating_user_id, dependent: :nullify, inverse_of: :initiating_user
  has_one :tracker_configuration, as: :configurable, dependent: :destroy
  has_many :created_chat_sessions, class_name: "ChatSession", foreign_key: :created_by_id, dependent: :nullify, inverse_of: :created_by
  has_many :pr_templates, dependent: :destroy

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  validates :account, presence: true

  after_create :assign_owner_role_if_first_user
  after_create :ensure_default_runner

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

    case resource
    when Account
      revoke_account_access!(resource)
    else
      membership.destroy
    end

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

  # Returns the user's settings, creating with defaults if not yet present.
  def settings
    user_setting || with_lock { reload_user_setting || create_user_setting! }
  end

  # Convenience method for getting account membership
  def account_membership_for(account)
    account_memberships.find_by(account: account)
  end

  # Convenience method for getting project membership
  def project_membership_for(project)
    project_memberships.find_by(project: project)
  end

  def active_for_authentication?
    super && !account&.deactivated?
  end

  def inactive_message
    return :deactivated_account if account&.deactivated?

    super
  end

  def operator?
    OperatorConsole::Access.allowed?(self)
  end

  def provider_for(runner)
    return runner if runner.is_a?(Provider)
    return unless runner.is_a?(Runner)

    scope = providers.kept_only.where(provider_key: runner.runner_key)
    scope = scope.where(auth_type: runner.auth_type) if runner.auth_type.present?
    if runner.api_key?
      scope = scope.where(
        provider_api_key_id: runner.provider_api_key_id,
        integration_credential_id: runner.integration_credential_id
      )
    end

    if runner.auth_type.blank?
      scope.where(auth_type: "subscription").ordered.first || scope.ordered.first
    else
      scope.ordered.first
    end
  end

  def revoke_account_access!(account)
    with_lock do
      membership = account_memberships.find_by(account: account)
      return false unless membership

      if account_id == account.id
        successor_membership = account_memberships.where.not(id: membership.id).order(:id).first

        if successor_membership
          update!(account: successor_membership.account)
          membership.destroy!
        else
          destroy!
        end
      else
        membership.destroy!
      end
    end

    true
  end

  private

  def assign_owner_role_if_first_user
    return unless account.users.count == 1

    add_role(:owner, account)
  end

  def ensure_default_runner
    Runner.ensure_default_for(self)
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
