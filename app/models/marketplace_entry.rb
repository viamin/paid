# frozen_string_literal: true

class MarketplaceEntry < ApplicationRecord
  ENTRY_TYPES = %w[skill agent plugin mcp_server prompt_pack provider_config enhancement other].freeze
  PROMPT_COMPATIBLE_ENTRY_TYPES = %w[skill agent prompt_pack enhancement other].freeze
  TEAM_SCOPES = %w[account private].freeze
  STATUSES = %w[draft active deprecated].freeze

  attr_accessor :canonical_artifact_json, :renderers_json, :compatibility_constraints_json,
    :review_metadata_json, :automatic_enabled, :automatic_conditions_json,
    :automatic_rationale, :team_default_enabled, :team_default_conditions_json,
    :team_default_rationale

  belongs_to :account
  belongs_to :current_version, class_name: "MarketplaceEntryVersion", optional: true

  has_many :marketplace_entry_versions, dependent: :destroy
  has_many :marketplace_entry_rules, -> { order(:mode, :position, :id) }, dependent: :destroy
  has_many :agent_run_marketplace_entries, dependent: :destroy
  has_many :agent_runs, through: :agent_run_marketplace_entries

  validates :name, presence: true, length: { maximum: 255 }
  validates :entry_type, presence: true, inclusion: { in: PROMPT_COMPATIBLE_ENTRY_TYPES }
  validates :provider, length: { maximum: 100 }, allow_nil: true
  validates :provider_format, presence: true, length: { maximum: 100 }
  validates :added_by_name, presence: true, length: { maximum: 255 }
  validates :added_by_email, presence: true, length: { maximum: 255 }
  validates :team_scope, presence: true, inclusion: { in: TEAM_SCOPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :tags_are_strings
  validate :current_version_belongs_to_entry

  scope :active, -> { where(status: "active") }
  scope :prompt_compatible, -> { where(entry_type: PROMPT_COMPATIBLE_ENTRY_TYPES) }
  scope :draft, -> { where(status: "draft") }
  scope :deprecated, -> { where(status: "deprecated") }
  scope :ordered, -> { order(:name, :id) }
  scope :search, lambda { |query|
    normalized_query = query.to_s.strip
    next all if normalized_query.blank?

    pattern = "%#{sanitize_sql_like(normalized_query)}%"
    where(
      "name ILIKE :pattern OR description ILIKE :pattern OR usage_guidance ILIKE :pattern",
      pattern:
    )
  }

  def self.ransackable_attributes(_auth_object = nil)
    %w[name entry_type provider provider_format team_scope status added_by_name added_by_email created_at updated_at]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[account current_version]
  end

  def create_version!(attributes = {})
    with_lock do
      next_version = (marketplace_entry_versions.maximum(:version) || 0) + 1
      safe_attributes = attributes.except(:version, "version")

      version = marketplace_entry_versions.create!(safe_attributes.merge(version: next_version))
      update!(current_version: version)
      version
    end
  end

  def tags_csv
    Array(tags).join(", ")
  end

  def tags_csv=(value)
    self.tags = value.to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  def active?
    status == "active"
  end

  private

  def tags_are_strings
    return if tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) }

    errors.add(:tags, "must be an array of strings")
  end

  def current_version_belongs_to_entry
    return if current_version.nil?
    return if current_version.marketplace_entry_id == id

    errors.add(:current_version, "must belong to this marketplace entry")
  end
end
