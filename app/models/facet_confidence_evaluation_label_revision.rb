# frozen_string_literal: true

# Append-only post-unblinding correction to a frozen reference label.
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluationLabelRevision < ApplicationRecord
  belongs_to :facet_confidence_evaluation, inverse_of: :label_revisions
  belongs_to :facet_confidence_evaluation_label, inverse_of: :revisions
  belongs_to :revised_by, class_name: "User"

  validates :case_id, :verdict, :intent_band, :technical_band, :readiness,
    :cited_evidence_reference, :reason, :revised_at, presence: true
  validates :verdict, inclusion: { in: FacetConfidenceEvaluationLabel::VERDICTS }
  validates :intent_band, :technical_band, inclusion: { in: FacetConfidenceEvaluationLabel::BANDS }
  validates :readiness, inclusion: { in: FacetConfidenceEvaluationLabel::READINESS }
  validate :readiness_follows_bands

  private

  def readiness_follows_bands
    expected = verdict == "completed" && intent_band == "at_or_above_threshold" && technical_band == "at_or_above_threshold" ? "ready" : "not_ready"
    errors.add(:readiness, "must follow the judged bands (#{expected})") unless readiness == expected
  end
end
