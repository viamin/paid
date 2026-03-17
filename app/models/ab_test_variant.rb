# frozen_string_literal: true

class AbTestVariant < ApplicationRecord
  belongs_to :ab_test
  belongs_to :prompt_version

  has_many :assignments, class_name: "AbTestAssignment", dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :ab_test_id }
  validates :weight, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validate :prompt_version_belongs_to_prompt

  def record_quality_score!(score)
    return if score.nil?

    self.class.where(id: id).update_all(
      "sample_count = sample_count + 1, " \
      "total_quality_score = total_quality_score + #{self.class.connection.quote(score.to_f)}, " \
      "avg_quality_score = (total_quality_score + #{self.class.connection.quote(score.to_f)}) / (sample_count + 1), " \
      "updated_at = #{self.class.connection.quote(Time.current)}"
    )
    reload
  end

  private

  def prompt_version_belongs_to_prompt
    return unless prompt_version_id && ab_test_id
    return if prompt_version&.prompt_id == ab_test&.prompt_id

    errors.add(:prompt_version, "must belong to the same prompt as the A/B test")
  end
end
