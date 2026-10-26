# frozen_string_literal: true

# Append-only post-unblinding correction. The original label and its frozen
# comparison remain the evidence used by the report. @spec FACET-CONFIDENCE-022
class FacetConfidenceEvaluationLabelRevision < ApplicationRecord
  belongs_to :facet_confidence_evaluation
  belongs_to :facet_confidence_evaluation_label
  belongs_to :recorded_by, class_name: "User"

  validates :verdict, inclusion: { in: FacetConfidenceEvaluationLabel::VERDICTS }
  validates :intent_band, :technical_band, inclusion: { in: FacetConfidenceEvaluationLabel::BANDS }
  validates :readiness, inclusion: { in: FacetConfidenceEvaluationLabel::READINESS }
  validates :cited_evidence_reference, :reason, :recorded_at, presence: true
  validate :readiness_follows_bands

  private

  def readiness_follows_bands
    expected = verdict == "completed" && intent_band == "at_or_above_threshold" && technical_band == "at_or_above_threshold" ? "ready" : "not_ready"
    errors.add(:readiness, "must follow the judged bands (#{expected})") unless readiness == expected
  end
end
