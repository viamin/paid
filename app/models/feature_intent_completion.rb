# frozen_string_literal: true

# @spec CONFIDENCE-DELIVERY-008 @spec CONFIDENCE-DELIVERY-011 @spec CONFIDENCE-DELIVERY-012
class FeatureIntentCompletion < ApplicationRecord
  STATUSES = %w[pending complete].freeze

  belongs_to :feature_intent
  belongs_to :completion_issue, class_name: "Issue", optional: true
  has_many :forward_work_items, class_name: "FeatureIntentForwardWorkItem", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :cycle, numericality: { only_integer: true, greater_than: 0 }
  validate :completion_issue_belongs_to_feature_project

  private

  # @spec CONFIDENCE-DELIVERY-008 @spec CONFIDENCE-DELIVERY-011
  def completion_issue_belongs_to_feature_project
    return if completion_issue.blank? || feature_intent.blank?
    return if completion_issue.project_id == feature_intent.project_id

    errors.add(:completion_issue, "must belong to the feature intent's project")
  end
end
