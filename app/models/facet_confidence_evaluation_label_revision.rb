# frozen_string_literal: true

# Append-only post-unblinding correction to a frozen reference judgment. The
# original FacetConfidenceEvaluationLabel is never overwritten, so reports can
# distinguish the blinded baseline from later judge reconsideration.
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluationLabelRevision < ApplicationRecord
  belongs_to :facet_confidence_evaluation_label
  belongs_to :revised_by, class_name: "User"

  validates :verdict, inclusion: { in: FacetConfidenceEvaluationLabel::VERDICTS }
  validates :intent_band, :technical_band, inclusion: { in: FacetConfidenceEvaluationLabel::BANDS }
  validates :readiness, inclusion: { in: FacetConfidenceEvaluationLabel::READINESS }
  validates :cited_evidence_reference, :reason, :revision_reason, :revised_at, presence: true
  validate :readiness_follows_bands

  private

  def readiness_follows_bands
    return if readiness == readiness_from_bands

    errors.add(:readiness, "must follow the corrected bands (#{readiness_from_bands})")
  end

  def readiness_from_bands
    return "ready" if verdict == "completed" && intent_band == "at_or_above_threshold" && technical_band == "at_or_above_threshold"

    "not_ready"
  end
end
