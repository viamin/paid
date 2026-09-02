# frozen_string_literal: true

require "digest"

class StyleGuide < ApplicationRecord
  has_logidze
  LANGUAGES = %w[ruby javascript typescript python go rust].freeze
  COMPRESSION_FAILED_THRESHOLD = 15.minutes
  SNAPSHOT_CREATED_BY = "manual"

  belongs_to :account, optional: true
  belongs_to :project, optional: true
  belongs_to :current_version, class_name: "StyleGuideVersion", optional: true

  has_many :style_guide_versions, dependent: :destroy
  has_many :style_guide_ab_tests, dependent: :destroy
  has_many :style_guide_run_exposures, dependent: :nullify

  before_validation :set_account_from_project, if: -> { project.present? && account.nil? }
  before_update :clear_compression, if: :will_save_change_to_raw_content?
  after_create :create_initial_version_snapshot!
  after_update :create_raw_content_version_snapshot!, if: :saved_change_to_raw_content?
  after_update :sync_current_version_compression!, if: :saved_change_to_compressed_artifact?

  validates :name, presence: true, length: { maximum: 255 }
  validates :name, uniqueness: { conditions: -> { where(account_id: nil, project_id: nil) } }, if: :global?
  validates :name, uniqueness: { scope: :account_id, conditions: -> { where(project_id: nil) } }, if: :account_level?
  validates :name, uniqueness: { scope: :project_id }, if: :project_level?
  validates :raw_content, presence: true
  validates :language, inclusion: { in: LANGUAGES }, allow_nil: true
  validates :account, presence: true, if: :project_level?
  validate :project_belongs_to_account, if: -> { project.present? && account.present? }
  validate :current_version_belongs_to_style_guide

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :global, -> { where(account_id: nil, project_id: nil) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }
  scope :by_language, ->(language) { where(language: language) }
  scope :compressed, -> { where.not(compressed_content: [ nil, "" ]) }

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

  def compression_current?
    return false if compressed_content.blank?

    raw_content_digest = compression_metadata["raw_content_sha256"]
    raw_content_digest.blank? || raw_content_digest == current_raw_content_sha256
  end

  def compression_state(now: Time.current)
    return :compressed if compression_current?
    return :failed if compression_failed?(now: now)

    :stale
  end

  def raw_content_written_at
    parse_metadata_time(compression_metadata["raw_content_updated_at"]) || updated_at || created_at || Time.current
  end

  def last_compressed_at
    parse_metadata_time(compression_metadata["compressed_at"])
  end

  # Resolves applicable style guides for a given project, using inheritance:
  # project > account > global. Returns applicable style guides deduplicated
  # by name with most-specific-wins ordering.
  #
  # @param project [Project] The project context
  # @return [ActiveRecord::Relation] Style guides ordered by specificity
  def self.resolve_for(project)
    detected_language = Prompts::LanguageCommands.detected_language(project)
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
      .where(language: [ nil, detected_language ])
      .select("DISTINCT ON (name) id")
      .order(Arel.sql("name"), specificity_order)

    where(id: deduped_ids).order(specificity_order, :name)
  end

  # Default maximum raw content bytes to inject when compression hasn't been performed.
  # Overridden by UserSetting#style_guide_max_raw_prompt_bytes at runtime.
  DEFAULT_MAX_RAW_PROMPT_BYTES = 8_000

  # Returns compressed content for injection into agent prompts.
  # Falls back to truncated raw content if compression has not been performed.
  #
  # @return [String, nil] The content suitable for prompt injection
  def content_for_prompt
    return compressed_content if compressed_content.present?
    return if raw_content.blank?

    max_bytes = resolve_max_raw_prompt_bytes
    return raw_content if raw_content.bytesize <= max_bytes

    truncate_to_byte_limit(raw_content, max_bytes)
  end

  private

  def current_version_belongs_to_style_guide
    return if current_version.nil?
    return if current_version.style_guide_id == id

    errors.add(:current_version, "must belong to this style guide")
  end

  def current_raw_content_sha256
    Digest::SHA256.hexdigest(raw_content.to_s)
  end

  def compression_failed?(now:)
    compressed_content.blank? && raw_content_written_at <= now - COMPRESSION_FAILED_THRESHOLD
  end

  def parse_metadata_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def truncate_to_byte_limit(text, max_bytes)
    truncated = +""
    text.each_char do |char|
      break if truncated.bytesize + char.bytesize > max_bytes
      truncated << char
    end
    truncated
  end

  def resolve_max_raw_prompt_bytes
    return DEFAULT_MAX_RAW_PROMPT_BYTES unless project

    settings = AgentRuns::UserSettingsResolver.call(project: project, strict: false)
    settings&.style_guide_max_raw_prompt_bytes || DEFAULT_MAX_RAW_PROMPT_BYTES
  end

  def clear_compression
    self.compressed_content = nil
    self.compression_metadata = { "raw_content_updated_at" => Time.current.iso8601 }
  end

  def create_initial_version_snapshot!
    version = create_version_snapshot!(
      created_by: created_by_for_snapshot,
      change_notes: "Initial version"
    )
    update_columns(current_version_id: version.id)
  end

  def create_raw_content_version_snapshot!
    version = create_version_snapshot!(
      created_by: created_by_for_snapshot,
      parent_version: current_version,
      change_notes: "Updated style guide content"
    )
    update_columns(current_version_id: version.id)
  end

  def create_version_snapshot!(created_by:, change_notes:, parent_version: nil)
    next_version = (style_guide_versions.maximum(:version) || 0) + 1

    style_guide_versions.create!(
      version: next_version,
      raw_content: raw_content,
      compressed_content: compressed_content,
      compression_metadata: compression_metadata || {},
      created_by: created_by,
      change_notes: change_notes,
      parent_version: parent_version
    )
  end

  def created_by_for_snapshot
    SNAPSHOT_CREATED_BY
  end

  def saved_change_to_compressed_artifact?
    saved_change_to_compressed_content? || saved_change_to_compression_metadata?
  end

  def sync_current_version_compression!
    return unless current_version
    return unless current_version.raw_content == raw_content

    current_version.update_columns(
      compressed_content: compressed_content,
      compression_metadata: compression_metadata || {},
      updated_at: Time.current
    )
  end

  def set_account_from_project
    self.account = project.account
  end

  def project_belongs_to_account
    return if project.account_id == account_id

    errors.add(:project, "must belong to the same account")
  end
end
