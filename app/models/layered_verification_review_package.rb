# frozen_string_literal: true

class LayeredVerificationReviewPackage < ApplicationRecord
  # @spec LAYERED-VERIFY-023
  belongs_to :project

  validates :package_identity, presence: true
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validates :package_identity, uniqueness: { scope: [ :project_id, :revision ] }

  def self.record!(project:, package_identity:, bound_inputs:)
    previous = where(project:, package_identity:).order(revision: :desc).first
    return previous if previous&.bound_inputs == bound_inputs

    create!(project:, package_identity:, revision: previous ? previous.revision + 1 : 1, bound_inputs:)
  end
end
