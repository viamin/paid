# frozen_string_literal: true

class StyleGuideAbTestAssignment < ApplicationRecord
  belongs_to :style_guide_ab_test
  belongs_to :style_guide_ab_test_variant
  belongs_to :agent_run

  has_many :style_guide_run_exposures, dependent: :nullify

  validates :agent_run_id, uniqueness: { scope: :style_guide_ab_test_id }
  validate :variant_matches_test

  private

  def variant_matches_test
    return if style_guide_ab_test.nil? || style_guide_ab_test_variant.nil?
    return if style_guide_ab_test_variant.style_guide_ab_test_id == style_guide_ab_test_id

    errors.add(:style_guide_ab_test_variant, "must belong to the same style guide A/B test")
  end
end
