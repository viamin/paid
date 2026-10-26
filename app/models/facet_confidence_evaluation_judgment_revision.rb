# frozen_string_literal: true

# Immutable, attributed correction made after a reference set is unblinded.
# The original label remains the blinded comparison evidence; revisions make
# later human reconsideration auditable without rewriting that evidence.
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluationJudgmentRevision < ApplicationRecord
  belongs_to :facet_confidence_evaluation_label
  belongs_to :revised_by, class_name: "User"

  validates :verdict, inclusion: { in: FacetConfidenceEvaluationLabel::VERDICTS }
  validates :intent_band, :technical_band, inclusion: { in: FacetConfidenceEvaluationLabel::BANDS }
  validates :readiness, inclusion: { in: FacetConfidenceEvaluationLabel::READINESS }
  validates :cited_evidence_reference, :reason, :revised_at, presence: true
  validate :readiness_follows_bands

  private

  def readiness_follows_bands
    expected = if verdict == "completed" && intent_band == "at_or_above_threshold" && technical_band == "at_or_above_threshold"
      "ready"
    else
      "not_ready"
    end
    errors.add(:readiness, "must follow the judged bands (#{expected})") unless readiness == expected
  end
end
