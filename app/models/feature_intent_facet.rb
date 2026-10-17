# frozen_string_literal: true

# @spec FACET-CONFIDENCE-001 @spec FACET-CONFIDENCE-002
class FeatureIntentFacet < ApplicationRecord
  include TenantScoped
  has_logidze

  belongs_to :account
  belongs_to :feature_intent
  belongs_to :issue, optional: true
  belongs_to :feature_intent_decision, optional: true

  has_many :directions, class_name: "FeatureIntentFacetDirection", dependent: :destroy
  has_many :evidence, class_name: "FeatureIntentFacetEvidence", dependent: :restrict_with_error
  has_many :issue_prerequisites, class_name: "FeatureIntentIssuePrerequisite", dependent: :restrict_with_error

  validates :name, :design_claim, presence: true
  validates :evidence_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :tenant_owns_links

  private

  def tenant_owns_links
    errors.add(:feature_intent, "must belong to the facet account") if feature_intent.present? && feature_intent.project.account_id != account_id
    errors.add(:issue, "must belong to the facet account") if issue.present? && issue.project.account_id != account_id
    return if feature_intent_decision.blank? || feature_intent_decision.feature_intent_id == feature_intent_id

    errors.add(:feature_intent_decision, "must belong to the facet feature")
  end
end
