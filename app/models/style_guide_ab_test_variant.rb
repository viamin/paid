# frozen_string_literal: true

class StyleGuideAbTestVariant < ApplicationRecord
  belongs_to :style_guide_ab_test
  belongs_to :style_guide_version

  has_many :style_guide_ab_test_assignments, dependent: :destroy

  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :style_guide_version_belongs_to_same_style_guide
  validate :style_guide_ab_test_variant_count_within_limit, on: :create

  def record_quality_score!(score)
    raise ArgumentError, "quality score must be a number between 0 and 1" unless score.is_a?(Numeric) && score.between?(0, 1)

    with_lock do
      score_decimal = BigDecimal(score.to_s)
      self.sample_count += 1
      self.total_quality_score = BigDecimal("0") if total_quality_score.nil?
      self.total_quality_score += score_decimal
      self.avg_quality_score = total_quality_score / sample_count
      save!
    end
  end

  private

  def style_guide_version_belongs_to_same_style_guide
    return if style_guide_version.nil? || style_guide_ab_test.nil?
    return if style_guide_version.style_guide_id == style_guide_ab_test.style_guide_id

    errors.add(:style_guide_version, "must belong to the same style guide as the test")
  end

  def style_guide_ab_test_variant_count_within_limit
    return if style_guide_ab_test.nil?
    return if style_guide_ab_test.style_guide_ab_test_variants.count < StyleGuideAbTest::MAX_VARIANTS + 1

    errors.add(:base, "A/B test cannot have more than #{StyleGuideAbTest::MAX_VARIANTS} variants plus control")
  end
end
