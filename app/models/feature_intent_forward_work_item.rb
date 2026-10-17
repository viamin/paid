# frozen_string_literal: true

# @spec CONFIDENCE-DELIVERY-008 @spec CONFIDENCE-DELIVERY-009
class FeatureIntentForwardWorkItem < ApplicationRecord
  STATUSES = %w[pending applied].freeze

  belongs_to :feature_intent_completion
  belongs_to :affected_issue, class_name: "Issue", optional: true
  belongs_to :follow_up_issue, class_name: "Issue", optional: true

  validates :fingerprint, presence: true, length: { maximum: 64 }, uniqueness: { scope: :feature_intent_completion_id }
  validates :status, inclusion: { in: STATUSES }
  validate :issues_belong_to_feature_project

  private

  # @spec CONFIDENCE-DELIVERY-008
  def issues_belong_to_feature_project
    validate_issue_project(:affected_issue)
    validate_issue_project(:follow_up_issue)
  end

  def validate_issue_project(association)
    issue = public_send(association)
    return if issue.blank? || feature_intent_completion.blank?
    return if issue.project_id == feature_intent_completion.feature_intent.project_id

    errors.add(association, "must belong to the feature intent's project")
  end
end
