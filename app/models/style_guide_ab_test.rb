# frozen_string_literal: true

class StyleGuideAbTest < ApplicationRecord
  STATUSES = AbTest::STATUSES
  MAX_VARIANTS = AbTest::MAX_VARIANTS
  ANALYSIS_INTERVAL = AbTest::ANALYSIS_INTERVAL

  belongs_to :account
  belongs_to :style_guide
  belongs_to :control_version, class_name: "StyleGuideVersion"
  belongs_to :winner_variant, class_name: "StyleGuideAbTestVariant", optional: true

  has_many :style_guide_ab_test_variants, dependent: :destroy
  has_many :style_guide_ab_test_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :confidence_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validate :variant_count_within_limit
  validate :control_version_belongs_to_style_guide
  validate :winner_variant_belongs_to_test

  scope :draft, -> { where(status: "draft") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :cancelled, -> { where(status: "cancelled") }

  include Experiments::AnalysisCache
  analysis_cache(
    analyzer_class: StyleGuideAbTests::Analyze,
    variants_association: :style_guide_ab_test_variants,
    call_keyword: :style_guide_ab_test
  )

  def draft?
    status == "draft"
  end

  def running?
    status == "running"
  end

  def completed?
    status == "completed"
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
    errors.add(:base, "another test is already running for this account")
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
  end

  def control_variant
    style_guide_ab_test_variants.find_by(is_control: true)
  end

  def sufficient_samples?
    style_guide_ab_test_variants.all? { |variant| variant.sample_count >= min_samples_per_variant }
  end

  private

  def samples_key
    total_samples = style_guide_ab_test_variants.sum(&:sample_count)
    total_bucket = (total_samples / Experiments::AnalysisCache::CACHE_BUCKET_SIZE) * Experiments::AnalysisCache::CACHE_BUCKET_SIZE
    variant_buckets = style_guide_ab_test_variants.sort_by(&:id)
      .map { |variant| "#{variant.id}:#{(variant.sample_count / Experiments::AnalysisCache::CACHE_BUCKET_SIZE) * Experiments::AnalysisCache::CACHE_BUCKET_SIZE}" }
      .join(",")
    "total:#{total_bucket}|#{variant_buckets}"
  end

  def variant_count_within_limit
    return if style_guide_ab_test_variants.size <= MAX_VARIANTS + 1

    errors.add(:style_guide_ab_test_variants, "cannot have more than #{MAX_VARIANTS} variants plus control")
  end

  def control_version_belongs_to_style_guide
    return if control_version.nil? || style_guide.nil?
    return if control_version.style_guide_id == style_guide_id

    errors.add(:control_version, "must belong to the same style guide")
  end

  def winner_variant_belongs_to_test
    return if winner_variant.nil?
    return if winner_variant.style_guide_ab_test_id == id

    errors.add(:winner_variant, "must belong to this style guide A/B test")
  end
end
