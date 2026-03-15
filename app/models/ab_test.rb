# frozen_string_literal: true

class AbTest < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  MAX_VARIANTS = 3

  belongs_to :prompt
  belongs_to :control_version, class_name: "PromptVersion"
  belongs_to :winner_variant, class_name: "AbTestVariant", optional: true

  has_many :ab_test_variants, dependent: :destroy
  has_many :ab_test_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than: 0 }
  validates :confidence_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :variant_count_within_limit
  validate :control_version_belongs_to_prompt
  validate :winner_variant_belongs_to_test

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :active, -> { where(status: %w[draft running]) }

  def draft?
    status == "draft"
  end

  def running?
    status == "running"
  end

  def completed?
    status == "completed"
  end

  def cancelled?
    status == "cancelled"
  end

  def start!
    raise ActiveRecord::RecordInvalid, self unless draft?

    update!(status: "running", started_at: Time.current)
  end

  def complete!(winner: nil)
    raise ActiveRecord::RecordInvalid, self unless running?

    update!(status: "completed", completed_at: Time.current, winner_variant: winner)
  end

  def cancel!
    raise ActiveRecord::RecordInvalid, self unless %w[draft running].include?(status)

    update!(status: "cancelled", completed_at: Time.current)
  end

  def control_variant
    ab_test_variants.find_by(is_control: true)
  end

  def non_control_variants
    ab_test_variants.where(is_control: false)
  end

  def sufficient_samples?
    ab_test_variants.all? { |v| v.sample_count >= min_samples_per_variant }
  end

  private

  def variant_count_within_limit
    return if ab_test_variants.size <= MAX_VARIANTS + 1 # +1 for control

    errors.add(:ab_test_variants, "cannot have more than #{MAX_VARIANTS} variants plus control")
  end

  def control_version_belongs_to_prompt
    return if control_version.nil? || prompt.nil?
    return if control_version.prompt_id == prompt_id

    errors.add(:control_version, "must belong to the same prompt")
  end

  def winner_variant_belongs_to_test
    return if winner_variant.nil?
    return if winner_variant.ab_test_id == id

    errors.add(:winner_variant, "must belong to this A/B test")
  end
end
