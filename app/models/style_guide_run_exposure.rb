# frozen_string_literal: true

class StyleGuideRunExposure < ApplicationRecord
  SOURCE_SCOPES = %w[project account global].freeze

  belongs_to :agent_run
  belongs_to :style_guide, optional: true
  belongs_to :style_guide_version
  belongs_to :style_guide_ab_test_assignment, optional: true

  validates :guide_name, presence: true
  validates :source_scope, presence: true, inclusion: { in: SOURCE_SCOPES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :injected_via, presence: true, length: { maximum: 50 }
  validate :assignment_matches_version

  private

  def assignment_matches_version
    return if style_guide_ab_test_assignment.nil?
    return if style_guide_ab_test_assignment.style_guide_ab_test_variant.style_guide_version_id == style_guide_version_id

    errors.add(:style_guide_ab_test_assignment, "must match the exposed style guide version")
  end
end
