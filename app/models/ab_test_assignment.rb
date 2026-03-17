# frozen_string_literal: true

class AbTestAssignment < ApplicationRecord
  belongs_to :ab_test
  belongs_to :ab_test_variant
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: true
  validate :variant_belongs_to_test

  private

  def variant_belongs_to_test
    return unless ab_test_id && ab_test_variant_id
    return if ab_test_variant&.ab_test_id == ab_test_id

    errors.add(:ab_test_variant, "must belong to the same A/B test")
  end
end
