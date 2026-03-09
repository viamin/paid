# frozen_string_literal: true

class AbTestVariant < ApplicationRecord
  belongs_to :ab_test
  belongs_to :prompt_version

  has_many :ab_test_assignments, dependent: :destroy

  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :prompt_version_belongs_to_same_prompt
  validate :ab_test_variant_count_within_limit, on: :create

  def record_quality_score!(score)
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

  def prompt_version_belongs_to_same_prompt
    return if prompt_version.nil? || ab_test.nil?

    if prompt_version.prompt_id != ab_test.prompt_id
      errors.add(:prompt_version, "must belong to the same prompt as the A/B test")
    end
  end

  def ab_test_variant_count_within_limit
    return if ab_test.nil?

    max_allowed = AbTest::MAX_VARIANTS + 1 # +1 for control
    if ab_test.ab_test_variants.count >= max_allowed
      errors.add(:base, "A/B test cannot have more than #{AbTest::MAX_VARIANTS} variants plus control")
    end
  end
end
