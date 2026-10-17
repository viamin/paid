# frozen_string_literal: true

# @spec FACET-CONFIDENCE-002
class FeatureIntentFacetEvidence < ApplicationRecord
  include TenantScoped

  self.table_name = "feature_intent_facet_evidence"

  belongs_to :account
  belongs_to :feature_intent_facet
  belongs_to :feature_intent_facet_direction, optional: true
  belongs_to :feature_intent_decision, optional: true
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :superseded_by, class_name: "FeatureIntentFacetEvidence", optional: true

  validates :source_type, :source_reference, :idempotency_key, :statement, :occurred_at, presence: true
  validates :idempotency_key, uniqueness: { scope: :account_id }
  validates :evidence_revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :tenant_owns_sources
  validate :direction_belongs_to_facet
  validate :decision_belongs_to_facet_feature
  validate :superseding_evidence_belongs_to_account_and_facet

  private

  def tenant_owns_sources
    errors.add(:feature_intent_facet, "must belong to the evidence account") if feature_intent_facet.present? && feature_intent_facet.account_id != account_id
    errors.add(:actor, "must belong to the evidence account") if actor.present? && actor.account_id != account_id
  end

  def direction_belongs_to_facet
    return if feature_intent_facet_direction.blank? || feature_intent_facet_direction.feature_intent_facet_id == feature_intent_facet_id

    errors.add(:feature_intent_facet_direction, "must belong to the evidence facet")
  end

  def decision_belongs_to_facet_feature
    return if feature_intent_decision.blank? || feature_intent_decision.feature_intent_id == feature_intent_facet&.feature_intent_id

    errors.add(:feature_intent_decision, "must belong to the evidence facet feature")
  end

  def superseding_evidence_belongs_to_account_and_facet
    return if superseded_by.blank? || (superseded_by.account_id == account_id && superseded_by.feature_intent_facet_id == feature_intent_facet_id)

    errors.add(:superseded_by, "must belong to the evidence account and facet")
  end
end
