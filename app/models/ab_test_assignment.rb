# frozen_string_literal: true

class AbTestAssignment < ApplicationRecord
  belongs_to :ab_test
  belongs_to :ab_test_variant
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: { scope: :ab_test_id }
  validate :ab_test_variant_matches_ab_test

  private

  def ab_test_variant_matches_ab_test
    return if ab_test_variant.nil? || ab_test.nil?

    if ab_test_variant.ab_test_id != ab_test_id
      errors.add(:ab_test_variant, "must belong to the same A/B test")
    end
  end
end
