# frozen_string_literal: true

class PrTemplate < ApplicationRecord
  PR_TYPES = %w[default feature bugfix hotfix].freeze

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
  validates :body, presence: true
  validates :pr_type, presence: true, inclusion: { in: PR_TYPES }
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :mutually_exclusive_scope
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }
  validate :user_belongs_to_account, if: -> { user.present? && account.present? }

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

  # Resolves the effective PR template for a given project, user, and PR type.
  # Priority: project > user > account (matched by name).
  # Disabled records act as tombstones — suppress inherited templates.
  #
  # @param project [Project] The project context
  # @param user [User, nil] The user context (optional)
  # @param pr_type [String] The PR type to filter by (default: "default")
  # @return [PrTemplate, nil] The highest-priority enabled template, or nil
  def self.resolve(project:, user: nil, pr_type: "default")
    account = project.account

    account_templates = for_account(account).where(pr_type: pr_type).ordered
    user_templates = if user && user.account_id == account.id
      for_user(user).where(pr_type: pr_type).ordered
    else
      none
    end
    project_templates = for_project(project).where(pr_type: pr_type).ordered

    by_name = {}
    account_templates.each { |t| by_name[t.name] = t }
    user_templates.each { |t| by_name[t.name] = t }
    project_templates.each { |t| by_name[t.name] = t }

    by_name.values.select(&:enabled?).min_by { |t| [ t.position, t.name ] }
  end

  # Renders the template body by replacing variable placeholders with values.
  #
  # Supported variables:
  #   {{issue_url}}, {{issue_number}}, {{issue_title}}, {{branch_name}},
  #   {{description}}, {{agent_summary}}
  #
  # @param variables [Hash<String,String>] Variable name => value pairs
  # @return [String] The rendered template body
  def render(variables = {})
    body.gsub(/\{\{(\w+)\}\}/) { |match| variables.key?(Regexp.last_match(1)) ? variables[Regexp.last_match(1)].to_s : match }
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
end
