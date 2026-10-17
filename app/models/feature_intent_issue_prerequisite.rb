# frozen_string_literal: true

# @spec FACET-CONFIDENCE-008
class FeatureIntentIssuePrerequisite < ApplicationRecord
  include TenantScoped
  has_logidze

  belongs_to :account
  belongs_to :feature_intent_issue_prerequisite_mapping
  belongs_to :feature_intent_facet
  belongs_to :feature_intent_facet_direction, optional: true

  validates :materiality_rationale, presence: true
  validate :tenant_owns_links
  validate :direction_belongs_to_facet
  validate :facet_belongs_to_linked_feature

  def readiness_payload
    {
      "id" => id || "facet-#{feature_intent_facet_id}",
      "rationale" => materiality_rationale,
      "assessment" => current_assessment_payload
    }
  end

  private

  def tenant_owns_links
    errors.add(:feature_intent_facet, "must belong to the prerequisite account") if feature_intent_facet.present? && feature_intent_facet.account_id != account_id
    return if feature_intent_issue_prerequisite_mapping.blank? || feature_intent_issue_prerequisite_mapping.account_id == account_id

    errors.add(:feature_intent_issue_prerequisite_mapping, "must belong to the prerequisite account")
  end

  def direction_belongs_to_facet
    return if feature_intent_facet_direction.blank? || feature_intent_facet_direction.feature_intent_facet_id == feature_intent_facet_id

    errors.add(:feature_intent_facet_direction, "must belong to the prerequisite facet")
  end

  def facet_belongs_to_linked_feature
    linked_feature_id = feature_intent_issue_prerequisite_mapping&.feature_intent_issue&.feature_intent_id
    return if feature_intent_facet.blank? || linked_feature_id.blank? || feature_intent_facet.feature_intent_id == linked_feature_id

    errors.add(:feature_intent_facet, "must belong to the mapped issue's feature")
  end

  def current_assessment_payload
    assessment = feature_intent_facet_direction&.assessments
      &.where(evidence_revision: feature_intent_facet.evidence_revision)
      &.order(created_at: :desc)&.first
    return {} unless assessment

    assessment.slice(:status, :evidence_revision, :intent_score, :technical_score)
      .transform_keys(&:to_s)
      .merge("current_evidence_revision" => feature_intent_facet.evidence_revision)
  end
end
