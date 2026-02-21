# frozen_string_literal: true

class Prompt < ApplicationRecord
  CATEGORIES = %w[planning coding review testing].freeze

  belongs_to :account, optional: true
  belongs_to :project, optional: true

  has_many :prompt_versions, dependent: :destroy
  belongs_to :current_version, class_name: "PromptVersion", optional: true

  validates :slug, presence: true, length: { maximum: 100 },
    format: { with: /\A[a-z0-9._-]+\z/, message: "can only contain lowercase letters, numbers, dots, hyphens, and underscores" },
    uniqueness: { scope: [:account_id, :project_id] }
  validates :name, presence: true, length: { maximum: 255 }
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :by_category, ->(category) { where(category: category) }
  scope :global, -> { where(account_id: nil, project_id: nil) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }

  def global?
    account_id.nil? && project_id.nil?
  end

  def account_level?
    account_id.present? && project_id.nil?
  end

  def project_level?
    project_id.present?
  end

  # Creates a new version for this prompt, auto-incrementing the version number.
  #
  # @param attributes [Hash] Attributes for the new PromptVersion
  # @return [PromptVersion] The newly created version
  def create_version!(attributes = {})
    next_version = (prompt_versions.maximum(:version) || 0) + 1
    version = prompt_versions.create!(attributes.merge(version: next_version))
    update!(current_version: version)
    version
  end

  # Resolves the effective prompt for a given project, using inheritance:
  # project > account > global
  #
  # @param slug [String] The prompt slug to resolve
  # @param project [Project] The project context
  # @return [Prompt, nil] The most specific active prompt matching the slug
  def self.resolve(slug, project:)
    candidates = active.where(slug: slug).where(
      "project_id = :project_id OR (account_id = :account_id AND project_id IS NULL) OR (account_id IS NULL AND project_id IS NULL)",
      project_id: project.id,
      account_id: project.account_id
    ).order(
      Arel.sql("CASE WHEN project_id IS NOT NULL THEN 0 WHEN account_id IS NOT NULL THEN 1 ELSE 2 END")
    )

    candidates.first
  end

  private

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end
end
