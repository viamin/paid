# frozen_string_literal: true

class AbTestVariant < ApplicationRecord
  belongs_to :ab_test
  belongs_to :prompt_version

  has_many :ab_test_assignments, dependent: :destroy

  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def record_quality_score!(score)
    self.sample_count += 1
    self.total_quality_score += score
    self.avg_quality_score = total_quality_score / sample_count
    save!
  end
end
