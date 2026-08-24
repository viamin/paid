# frozen_string_literal: true

class AbTest < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  MAX_VARIANTS = 3

  # Interval used for analysis bucketing; kept in sync with RecordResult's analysis
  # throttle so cache freshness aligns with write-path recomputation cadence.
  ANALYSIS_INTERVAL = 5

  belongs_to :prompt
  belongs_to :control_version, class_name: "PromptVersion"
  belongs_to :winner_variant, class_name: "AbTestVariant", optional: true

  has_many :ab_test_variants, dependent: :destroy
  has_many :ab_test_assignments, dependent: :destroy

  accepts_nested_attributes_for :ab_test_variants, allow_destroy: true,
    reject_if: ->(attrs) { attrs["prompt_version_id"].blank? && !ActiveModel::Type::Boolean.new.cast(attrs["_destroy"]) }

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :confidence_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :variant_count_within_limit
  validate :control_version_belongs_to_prompt
  validate :winner_variant_belongs_to_test

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :active, -> { where(status: %w[draft running]) }

  include Experiments::AnalysisCache
  analysis_cache(
    analyzer_class: AbTests::Analyze,
    variants_association: :ab_test_variants,
    call_keyword: :ab_test
  )

  def self.ransackable_attributes(auth_object = nil)
    %w[name status created_at started_at completed_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[prompt]
  end

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
    with_lock do
      reload
      unless draft?
        errors.add(:base, "cannot start a test that is #{status}")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(status: "running", started_at: Time.current)
    end
  rescue ActiveRecord::RecordNotUnique
    errors.add(:base, "another test is already running for this prompt")
    raise ActiveRecord::RecordInvalid, self
  end

  def complete!(winner: nil)
    with_lock do
      reload
      unless running?
        errors.add(:base, "cannot complete a test that is #{status}")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(status: "completed", completed_at: Time.current, winner_variant: winner)
    end
    record_quality_recovery_outcome!
  end

  def cancel!
    with_lock do
      reload
      unless %w[draft running].include?(status)
        errors.add(:base, "cannot cancel a test that is #{status}")
        raise ActiveRecord::RecordInvalid, self
      end
      update!(status: "cancelled", completed_at: Time.current)
    end
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

  def samples_key
    total_samples = ab_test_variants.sum(&:sample_count)
    total_bucket  = (total_samples / Experiments::AnalysisCache::CACHE_BUCKET_SIZE) * Experiments::AnalysisCache::CACHE_BUCKET_SIZE

    variant_buckets = ab_test_variants
                      .sort_by(&:id)
                      .map { |v| "#{v.id}:#{(v.sample_count / Experiments::AnalysisCache::CACHE_BUCKET_SIZE) * Experiments::AnalysisCache::CACHE_BUCKET_SIZE}" }
                      .join(",")

    "total:#{total_bucket}|#{variant_buckets}"
  end

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

  def record_quality_recovery_outcome!
    recovery_actions.find_each do |action|
      if evolved_winner?
        action.merge_result!(quality_recovery_result)
      else
        action.update!(status: "failed", result: quality_recovery_result)
      end
    end
  end

  def evolved_winner?
    winner_variant.present? && !winner_variant.is_control?
  end

  def recovery_actions
    QualityRecoveryAction
      .where(action_type: "prompt_evolution", status: "executing")
      .for_ab_test(id)
  end

  def quality_recovery_result
    {
      status: evolved_winner? ? "winner_found" : "no_evolved_winner",
      ab_test_id: id,
      prompt_id: prompt_id,
      winner_variant_id: winner_variant_id,
      winner_prompt_version_id: winner_variant&.prompt_version_id
    }
  end
end
