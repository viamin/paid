# frozen_string_literal: true

class PreCommitRequirement < ApplicationRecord
  CHECK_TYPES = %w[shell_command test_suite coverage security_scan].freeze
  FAILURE_BEHAVIORS = %w[block warn auto_fix].freeze

  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :user, optional: true

  before_validation :set_account_from_project, if: -> { project.present? && account.nil? }
  before_validation :set_account_from_user, if: -> { user.present? && project.nil? && account.nil? }

  validates :name, presence: true, length: { maximum: 255 }
  validates :name, uniqueness: { scope: [ :account_id ] },
    if: -> { project_id.nil? && user_id.nil? }
  validates :name, uniqueness: { scope: [ :project_id ] },
    if: -> { project_id.present? }
  validates :name, uniqueness: { scope: [ :user_id ] },
    if: -> { user_id.present? && project_id.nil? }
  validates :command, presence: true
  validates :check_type, presence: true, inclusion: { in: CHECK_TYPES }
  validates :failure_behavior, presence: true, inclusion: { in: FAILURE_BEHAVIORS }
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :mutually_exclusive_scope
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }
  validate :user_belongs_to_account, if: -> { user.present? && account.present? }
  validate :fix_command_requires_auto_fix

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:position, :name) }
  scope :for_account, ->(account) { where(account: account, project_id: nil, user_id: nil) }
  scope :for_project, ->(project) { where(project: project) }
  scope :for_user, ->(user) { where(user: user, project_id: nil) }

  def account_level?
    project_id.nil? && user_id.nil?
  end

  def project_level?
    project_id.present?
  end

  def user_level?
    user_id.present? && project_id.nil?
  end

  def auto_fix?
    failure_behavior == "auto_fix"
  end

  def blocking?
    failure_behavior != "warn"
  end

  # Resolves the effective pre-commit requirements for a given project and user,
  # merging account defaults with user and project overrides.
  # Priority: project > user > account (project-level requirements override
  # user-level, which override account-level, matched by name).
  #
  # @param project [Project] The project context
  # @param user [User, nil] The user context (optional)
  # @return [Array<PreCommitRequirement>] Ordered list of effective requirements
  def self.resolve(project:, user: nil)
    account = project.account

    account_reqs = for_account(account).ordered
    user_reqs = if user && user.account_id == account.id
      for_user(user).ordered
    else
      self.none
    end
    project_reqs = for_project(project).ordered

    # Merge: project overrides user overrides account (by name).
    # Disabled records act as tombstones — a disabled override suppresses
    # the inherited requirement. Filter out disabled after merging.
    by_name = {}
    account_reqs.each { |r| by_name[r.name] = r }
    user_reqs.each { |r| by_name[r.name] = r }
    project_reqs.each { |r| by_name[r.name] = r }

    by_name.values.select(&:enabled?).sort_by { |r| [ r.position, r.name ] }
  end

  private

  def set_account_from_project
    self.account = project.account
  end

  def set_account_from_user
    self.account = user.account
  end

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def user_belongs_to_account
    return if user.account_id == account_id

    errors.add(:user, "must belong to the same account")
  end

  def mutually_exclusive_scope
    return unless project_id.present? && user_id.present?

    errors.add(:base, "cannot be scoped to both a project and a user")
  end

  def fix_command_requires_auto_fix
    return unless fix_command.present? && failure_behavior != "auto_fix"

    errors.add(:fix_command, "can only be set when failure behavior is auto_fix")
  end
end
