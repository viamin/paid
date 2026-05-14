# frozen_string_literal: true

class Strategy < ApplicationRecord
  STATUSES = %w[draft active archived].freeze

  belongs_to :account, optional: true
  belongs_to :project, optional: true
  belongs_to :current_version, class_name: "StrategyVersion", optional: true

  has_many :strategy_versions, dependent: :destroy

  before_validation :set_account_from_project, if: -> { project.present? && account.nil? }

  validates :slug, presence: true, length: { maximum: 100 },
    format: { with: /\A[a-z0-9._-]+\z/, message: "can only contain lowercase letters, numbers, dots, hyphens, and underscores" }
  validates :slug, uniqueness: { conditions: -> { where(account_id: nil, project_id: nil) } }, if: :global?
  validates :slug, uniqueness: { scope: :account_id, conditions: -> { where(project_id: nil) } }, if: :account_level?
  validates :slug, uniqueness: { scope: :project_id }, if: :project_level?
  validates :name, presence: true, length: { maximum: 255 }
  validates :decision_type, presence: true, length: { maximum: 100 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :account, presence: true, if: :project_level?
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }
  validate :selection_rules_is_object
  validate :current_version_belongs_to_strategy

  scope :active, -> { where(status: "active") }
  scope :draft, -> { where(status: "draft") }
  scope :archived, -> { where(status: "archived") }
  scope :global, -> { where(account_id: nil, project_id: nil) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }
  scope :by_decision_type, ->(decision_type) { where(decision_type: decision_type) }

  def global?
    account_id.nil? && project_id.nil?
  end

  def account_level?
    account_id.present? && project_id.nil?
  end

  def project_level?
    project_id.present?
  end

  def create_version!(attributes = {})
    with_lock do
      next_version = (strategy_versions.maximum(:version) || 0) + 1
      safe_attributes = attributes.except(:version, "version")

      strategy_versions.create!(safe_attributes.merge(version: next_version))
    end
  end

  def create_pending_version!(attributes = {})
    with_lock do
      next_version = (strategy_versions.maximum(:version) || 0) + 1
      safe_attributes = attributes.except(:version, "version")
      safe_attributes.delete("promotion_state")
      safe_attributes.delete(:promotion_state)
      safe_attributes[:promotion_state] = "candidate"

      strategy_versions.create!(safe_attributes.merge(version: next_version))
    end
  end

  def pending_reviews
    strategy_versions.pending_review
  end

  private

  def set_account_from_project
    self.account = project.account
  end

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def selection_rules_is_object
    return if selection_rules.is_a?(Hash)

    errors.add(:selection_rules, "must be an object")
  end

  def current_version_belongs_to_strategy
    return if current_version.nil?
    if current_version.strategy_id != id
      errors.add(:current_version, "must belong to this strategy")
      return
    end

    return if current_version.active?

    errors.add(:current_version, "must be active before it can become current")
  end
end
