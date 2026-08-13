# frozen_string_literal: true

class StyleGuideVersion < ApplicationRecord
  IMMUTABLE_ATTRIBUTES = %w[
    raw_content
    version
    style_guide_id
    created_by_user_id
    parent_version_id
    created_by
    change_notes
  ].freeze
  REVIEW_STATUSES = %w[pending approved rejected].freeze

  belongs_to :style_guide
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_version, class_name: "StyleGuideVersion", optional: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true

  has_many :child_versions, class_name: "StyleGuideVersion", foreign_key: :parent_version_id, dependent: :nullify,
    inverse_of: :parent_version
  has_many :style_guide_ab_test_variants, dependent: :restrict_with_error
  has_many :style_guide_run_exposures, dependent: :restrict_with_error

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :style_guide_id }
  validates :raw_content, presence: true
  validates :review_status, inclusion: { in: REVIEW_STATUSES }, allow_nil: true
  validate :immutable_content_after_creation, on: :update
  validate :parent_version_belongs_to_style_guide

  scope :active, -> { where(retired_at: nil) }
  scope :retired, -> { where.not(retired_at: nil) }
  scope :pending_review, -> { where(review_status: "pending") }

  def content_for_prompt(project: style_guide.project)
    return compressed_content if compressed_content.present?
    return if raw_content.blank?

    max_bytes = project ? AgentRuns::UserSettingsResolver.call(project: project, strict: false)&.style_guide_max_raw_prompt_bytes : nil
    max_bytes ||= StyleGuide::DEFAULT_MAX_RAW_PROMPT_BYTES
    return raw_content if raw_content.bytesize <= max_bytes

    truncated = +""
    raw_content.each_char do |char|
      break if truncated.bytesize + char.bytesize > max_bytes

      truncated << char
    end
    truncated
  end

  private

  # @spec STYLE-GUIDE-EVOLUTION-001
  def immutable_content_after_creation
    return unless (changes.keys & IMMUTABLE_ATTRIBUTES).any?

    errors.add(:base, "style guide version content fields are immutable after creation")
  end

  # @spec STYLE-GUIDE-EVOLUTION-002
  def parent_version_belongs_to_style_guide
    return if parent_version.nil?
    return if parent_version.style_guide_id == style_guide_id

    errors.add(:parent_version, "must belong to the same style guide")
  end
end
