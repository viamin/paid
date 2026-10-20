# frozen_string_literal: true

# @spec FEATURE-APPROVAL-024
# A dependency edge captured from an issue tree when both endpoints are linked
# to the same feature intent. The snapshot keeps admission grounded in the
# approved tree instead of rediscovering arbitrary project dependencies later.
class FeatureIntentIssueDependency < ApplicationRecord
  belongs_to :feature_intent_issue
  belongs_to :depends_on_feature_intent_issue, class_name: "FeatureIntentIssue"

  validates :depends_on_feature_intent_issue_id, uniqueness: { scope: :feature_intent_issue_id }
  validate :endpoints_share_feature_intent
  validate :not_self_referential

  private

  def endpoints_share_feature_intent
    return if feature_intent_issue.blank? || depends_on_feature_intent_issue.blank?
    return if feature_intent_issue.feature_intent_id == depends_on_feature_intent_issue.feature_intent_id

    errors.add(:depends_on_feature_intent_issue, "must belong to the same feature intent")
  end

  def not_self_referential
    return unless feature_intent_issue_id == depends_on_feature_intent_issue_id

    errors.add(:depends_on_feature_intent_issue, "cannot be the same feature tree issue")
  end
end
