# frozen_string_literal: true

class Prompt < ApplicationRecord
  has_logidze
  CATEGORIES = %w[planning coding review testing].freeze

  attr_accessor :template, :system_prompt, :variables_text, :change_notes

  belongs_to :account, optional: true
  belongs_to :project, optional: true

  has_many :ab_tests, dependent: :destroy
  has_many :prompt_versions, dependent: :destroy
  belongs_to :current_version, class_name: "PromptVersion", optional: true

  before_validation :set_account_from_project, if: -> { project.present? && account.nil? }

  validates :slug, presence: true, length: { maximum: 100 },
    format: { with: /\A[a-z0-9._-]+\z/, message: "can only contain lowercase letters, numbers, dots, hyphens, and underscores" }
  validates :slug, uniqueness: { conditions: -> { where(account_id: nil, project_id: nil) } }, if: :global?
  validates :slug, uniqueness: { scope: :account_id, conditions: -> { where(project_id: nil) } }, if: :account_level?
  validates :slug, uniqueness: { scope: :project_id }, if: :project_level?
  validates :name, presence: true, length: { maximum: 255 }
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :account, presence: true, if: :project_level?
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }
  validate :current_version_must_be_activatable

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :by_category, ->(category) { where(category: category) }
  scope :global, -> { where(account_id: nil, project_id: nil) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }

  def self.ransackable_attributes(auth_object = nil)
    %w[name slug category active description created_at updated_at requires_review]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[account project]
  end

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
    with_lock do
      next_version = (prompt_versions.maximum(:version) || 0) + 1

      # Strip caller-supplied version keys to prevent overriding auto-increment.
      safe_attributes = attributes.except(:version, "version")

      version = prompt_versions.create!(safe_attributes.merge(version: next_version))
      update!(current_version: version)
      version
    end
  end

  # Creates a new version without promoting it to current_version. Used by the
  # prompt evolution pipeline when +requires_review+ is true so a human can
  # review the proposed variant before it becomes active.
  #
  # @param attributes [Hash] Attributes for the new PromptVersion (review_status
  #   defaults to "pending")
  # @return [PromptVersion] The newly created (unpromoted) version
  def create_pending_version!(attributes = {})
    with_lock do
      next_version = (prompt_versions.maximum(:version) || 0) + 1

      # Strip caller-supplied version keys to prevent overriding auto-increment.
      safe_attributes = attributes.except(:version, "version")
      safe_attributes[:review_status] ||= "pending"

      prompt_versions.create!(safe_attributes.merge(version: next_version))
    end
  end

  # Idempotent variant of +create_pending_version!+: when a previous attempt
  # already created a version with the given +idempotency_key+ (e.g. a Temporal
  # activity retry after a worker crash), reuse it instead of inserting a
  # duplicate (#2770). The version number is assigned only on first creation.
  #
  # @param idempotency_key [String] Stable dedup key for this version
  # @param attributes [Hash] Attributes for the new PromptVersion
  # @return [PromptVersion] The existing or newly created (unpromoted) version
  def find_or_create_pending_version_by!(idempotency_key:, **attributes)
    existing = prompt_versions.find_by(idempotency_key: idempotency_key)
    return existing if existing

    with_lock do
      existing = prompt_versions.find_by(idempotency_key: idempotency_key)
      return existing if existing

      next_version = (prompt_versions.maximum(:version) || 0) + 1
      safe_attributes = attributes.except(:version, "version")
      safe_attributes[:review_status] ||= "pending"

      prompt_versions.create!(safe_attributes.merge(version: next_version, idempotency_key: idempotency_key))
    end
  end

  def pending_reviews
    prompt_versions.pending_review
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
      # Safe use of Arel.sql: no user input is interpolated into this SQL string.
      # Prioritizes: project-level (0) > account-level (1) > global (2).
      Arel.sql("CASE WHEN project_id IS NOT NULL THEN 0 WHEN account_id IS NOT NULL THEN 1 ELSE 2 END")
    )

    candidates.first
  end

  private

  def set_account_from_project
    self.account = project.account
  end

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end

  def current_version_must_be_activatable
    return unless current_version
    return if current_version.activatable?

    errors.add(:current_version, "must be approved before it can become active")
  end
end
