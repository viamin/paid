# frozen_string_literal: true

# @spec FACET-CONFIDENCE-001 @spec FACET-CONFIDENCE-002
class FeatureIntentFacetAssessment < ApplicationRecord
  include TenantScoped

  STATUSES = %w[unknown pending completed failed superseded].freeze

  belongs_to :account
  belongs_to :feature_intent_facet_direction

  validates :status, inclusion: { in: STATUSES }
  validates :rubric_version, :model_version, presence: true
  validates :intent_score, :technical_score, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
  validate :direction_belongs_to_account
  validate :completed_assessment_has_known_scores

  private

  def direction_belongs_to_account
    return if feature_intent_facet_direction.blank? || feature_intent_facet_direction.account_id == account_id

    errors.add(:feature_intent_facet_direction, "must belong to the assessment account")
  end

  def completed_assessment_has_known_scores
    return unless status == "completed" && (intent_score.nil? || technical_score.nil?)

    errors.add(:base, "completed assessments require both scores")
  end
end
