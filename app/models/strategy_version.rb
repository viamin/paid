# frozen_string_literal: true

class StrategyVersion < ApplicationRecord
  IMMUTABLE_ATTRIBUTES = %w[
    content
    version
    strategy_id
    created_by_user_id
    parent_version_id
    provenance
    created_by
    reasoning
    change_notes
  ].freeze
  PROMOTION_STATES = %w[draft candidate active retired rejected].freeze

  belongs_to :strategy
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :parent_version, class_name: "StrategyVersion", optional: true
  belongs_to :promoted_by_user, class_name: "User", optional: true

  has_many :child_versions, class_name: "StrategyVersion", foreign_key: :parent_version_id, dependent: :nullify,
    inverse_of: :parent_version
  has_many :orchestration_decisions, foreign_key: :strategy_version_id, inverse_of: :strategy_version, dependent: :nullify

  validates :version, presence: true,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :strategy_id }
  validates :promotion_state, inclusion: { in: PROMOTION_STATES }
  validate :content_is_object
  validate :provenance_is_object
  validate :immutable_content_after_creation, on: :update
  validate :parent_version_belongs_to_strategy

  scope :draft, -> { where(promotion_state: "draft") }
  scope :candidate, -> { where(promotion_state: "candidate") }
  scope :active, -> { where(promotion_state: "active", retired_at: nil) }
  scope :retired, -> { where.not(retired_at: nil) }
  scope :rejected, -> { where(promotion_state: "rejected") }

  def retired?
    retired_at.present?
  end

  def active?
    promotion_state == "active" && !retired?
  end

  private

  def content_is_object
    return if content.is_a?(Hash)

    errors.add(:content, "must be an object")
  end

  def provenance_is_object
    return if provenance.is_a?(Hash)

    errors.add(:provenance, "must be an object")
  end

  def immutable_content_after_creation
    if (changes.keys & IMMUTABLE_ATTRIBUTES).any?
      errors.add(:base, "strategy version content fields are immutable after creation")
    end
  end

  def parent_version_belongs_to_strategy
    return if parent_version.nil?
    return if parent_version.strategy_id == strategy_id

    errors.add(:parent_version, "must belong to the same strategy")
  end
end
