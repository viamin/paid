# frozen_string_literal: true

class MarketplaceEntry < ApplicationRecord
  ENTRY_TYPES = %w[
    skill
    agent
    prompt_pack
    policy_pack
    enhancement
    tool
    plugin
    collector
    workflow_strategy
    integration
    mcp_server
    provider_config
    other
  ].freeze
  EXTENSION_POINTS = %w[
    collectors
    policies
    tools
    workflow_strategies
    prompts
    integrations
  ].freeze
  # Private visibility needs an owner/user reference that marketplace entries
  # do not currently persist. Keep the scope account-wide until ownership
  # semantics exist.
  TEAM_SCOPES = %w[account].freeze
  STATUSES = %w[draft active deprecated].freeze
  CERTIFICATION_STATUSES = %w[uncertified self_attested verified certified].freeze
  SUPPORT_TIERS = %w[community partner first_party].freeze

  attr_accessor :canonical_artifact_json, :renderers_json, :compatibility_constraints_json,
    :review_metadata_json, :automatic_enabled, :automatic_conditions_json,
    :automatic_rationale, :team_default_enabled, :team_default_conditions_json,
    :team_default_rationale

  belongs_to :account
  belongs_to :current_version, class_name: "MarketplaceEntryVersion", optional: true

  before_destroy :prevent_destroy_when_attached_to_runs

  has_many :marketplace_entry_versions, dependent: :destroy
  has_many :marketplace_entry_rules, -> { order(:mode, :position, :id) }, dependent: :destroy
  has_many :agent_run_marketplace_entries, dependent: :restrict_with_error
  has_many :agent_runs, through: :agent_run_marketplace_entries

  validates :name, presence: true, length: { maximum: 255 }
  validates :entry_type, presence: true, inclusion: { in: ENTRY_TYPES }
  validates :provider, length: { maximum: 100 }, allow_nil: true
  validates :provider_format, presence: true, length: { maximum: 100 }
  validates :added_by_name, presence: true, length: { maximum: 255 }
  validates :added_by_email, presence: true, length: { maximum: 255 }
  validates :team_scope, presence: true, inclusion: { in: TEAM_SCOPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :certification_status, presence: true, inclusion: { in: CERTIFICATION_STATUSES }
  validates :support_tier, presence: true, inclusion: { in: SUPPORT_TIERS }
  validates :documentation_url, length: { maximum: 500 }, allow_nil: true
  validates :source_code_url, length: { maximum: 500 }, allow_nil: true
  validate :tags_are_strings
  validate :extension_points_are_strings
  validate :extension_points_are_known
  validate :current_version_belongs_to_entry

  scope :active, -> { where(status: "active") }
  scope :draft, -> { where(status: "draft") }
  scope :deprecated, -> { where(status: "deprecated") }
  scope :ordered, -> { order(:name, :id) }
  scope :with_entry_type, ->(entry_type) { entry_type.present? ? where(entry_type: entry_type.to_s) : all }
  scope :with_certification_status, lambda { |certification_status|
    certification_status.present? ? where(certification_status: certification_status.to_s) : all
  }
  scope :with_extension_point, lambda { |extension_point|
    next all if extension_point.blank?

    where("extension_points @> ?", [ extension_point.to_s ].to_json)
  }
  scope :tagged_with, lambda { |tag|
    next all if tag.blank?

    where("tags @> ?", [ tag.to_s ].to_json)
  }
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
    %w[current_version]
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

  def prevent_destroy_when_attached_to_runs
    return true unless agent_run_marketplace_entries.exists?

    errors.add(:base, "cannot delete marketplace entries that have been attached to agent runs")
    throw(:abort)
  end

  def tags_are_strings
    return if tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) }

    errors.add(:tags, "must be an array of strings")
  end

  def extension_points_are_strings
    return if extension_points.is_a?(Array) && extension_points.all? { |value| value.is_a?(String) }

    errors.add(:extension_points, "must be an array of strings")
  end

  def extension_points_are_known
    return unless extension_points.is_a?(Array)

    unknown_values = extension_points - EXTENSION_POINTS
    return if unknown_values.empty?

    errors.add(:extension_points, "contains unsupported values: #{unknown_values.join(', ')}")
  end

  def current_version_belongs_to_entry
    return if current_version.nil?
    return if current_version.marketplace_entry_id == id

    errors.add(:current_version, "must belong to this marketplace entry")
  end
end
