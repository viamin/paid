# frozen_string_literal: true

class PromptVersion < ApplicationRecord
  IMMUTABLE_ATTRIBUTES = %w[template version prompt_id created_by_user_id parent_version_id variables system_prompt created_by change_notes].freeze

  REVIEW_STATUSES = %w[pending approved rejected].freeze

  belongs_to :prompt
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_version, class_name: "PromptVersion", optional: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true

  has_many :agent_runs, dependent: :nullify
  has_many :ab_test_variants, dependent: :restrict_with_error
  has_many :quality_metrics, dependent: :nullify

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :prompt_id }
  validates :template, presence: true
  validates :review_status, inclusion: { in: REVIEW_STATUSES }, allow_nil: true

  validate :immutable_content_after_creation, on: :update

  scope :pending_review, -> { where(review_status: "pending") }
  scope :approved, -> { where(review_status: "approved") }
  scope :rejected, -> { where(review_status: "rejected") }
  scope :awaiting_review, -> { pending_review }

  # Renders the template by interpolating variables in a single pass.
  # Values that themselves contain `{{other_var}}` substrings are NOT
  # re-substituted (no gsub-ordering bug).
  #
  # @param vars [Hash] Variable name-value pairs to interpolate
  # @return [String] The rendered template
  def render(vars = {})
    Prompts::Render.interpolate(template, vars)
  end

  def pending_review?
    review_status == "pending"
  end

  def approved?
    review_status == "approved"
  end

  def rejected?
    review_status == "rejected"
  end

  # True when this version participates in the review workflow (was created
  # while the prompt's review gate was enabled), regardless of outcome.
  def under_review?
    review_status.present?
  end

  private

  def immutable_content_after_creation
    if (changes.keys & IMMUTABLE_ATTRIBUTES).any?
      errors.add(:base, "prompt version content fields are immutable after creation")
    end
  end
end
