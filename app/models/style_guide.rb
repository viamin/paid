# frozen_string_literal: true

class StyleGuide < ApplicationRecord
  LANGUAGES = %w[ruby javascript typescript python go rust].freeze

  belongs_to :account, optional: true
  belongs_to :project, optional: true

  before_validation :set_account_from_project, if: -> { project.present? && account.nil? }
  before_update :clear_compression, if: :will_save_change_to_raw_content?

  validates :name, presence: true, length: { maximum: 255 }
  validates :name, uniqueness: { conditions: -> { where(account_id: nil, project_id: nil) } }, if: :global?
  validates :name, uniqueness: { scope: :account_id, conditions: -> { where(project_id: nil) } }, if: :account_level?
  validates :name, uniqueness: { scope: :project_id }, if: :project_level?
  validates :raw_content, presence: true
  validates :language, inclusion: { in: LANGUAGES }, allow_nil: true
  validates :account, presence: true, if: :project_level?
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :global, -> { where(account_id: nil, project_id: nil) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }
  scope :by_language, ->(language) { where(language: language) }
  scope :compressed, -> { where.not(compressed_content: nil) }

  def self.ransackable_attributes(auth_object = nil)
    %w[name language active created_at updated_at]
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

  def compressed?
    compressed_content.present?
  end

  # Resolves applicable style guides for a given project, using inheritance:
  # project > account > global. Returns applicable style guides deduplicated
  # by name with most-specific-wins ordering.
  #
  # @param project [Project] The project context
  # @return [ActiveRecord::Relation] Style guides ordered by specificity
  def self.resolve_for(project)
    specificity_order = Arel.sql(
      "CASE WHEN project_id IS NOT NULL THEN 0 WHEN account_id IS NOT NULL THEN 1 ELSE 2 END"
    )

    deduped_ids = active
      .where(
        "project_id = :project_id OR (account_id = :account_id AND project_id IS NULL) OR " \
        "(account_id IS NULL AND project_id IS NULL)",
        project_id: project.id,
        account_id: project.account_id
      )
      .select("DISTINCT ON (name) id")
      .order(Arel.sql("name"), specificity_order)

    where(id: deduped_ids).order(specificity_order, :name)
  end

  # Returns compressed content for injection into agent prompts.
  # Falls back to raw content if compression has not been performed.
  #
  # @return [String] The content suitable for prompt injection
  def content_for_prompt
    compressed_content.presence || raw_content
  end

  private

  def clear_compression
    self.compressed_content = nil
    self.compression_metadata = {}
  end

  def set_account_from_project
    self.account = project.account
  end

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end
end
