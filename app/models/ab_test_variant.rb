# frozen_string_literal: true

class AbTestVariant < ApplicationRecord
  belongs_to :ab_test
  belongs_to :prompt_version

  validates :name, presence: true, uniqueness: { scope: :ab_test_id }
  validates :weight, numericality: { greater_than: 0, less_than_or_equal_to: 100 }

  def record_quality_score!(score)
    return if score.nil?

    self.class.where(id: id).update_all(
      "sample_count = sample_count + 1, " \
      "total_quality_score = total_quality_score + #{self.class.connection.quote(score.to_f)}, " \
      "avg_quality_score = (total_quality_score + #{self.class.connection.quote(score.to_f)}) / (sample_count + 1)"
    )
    reload
  end
end
