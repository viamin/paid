# frozen_string_literal: true

# Durable blinded reference judgment for one corpus case of a
# facet-confidence closeout evaluation. One row per (evaluation, case) so
# saves are updates-in-place and resume is free. `state` distinguishes
# labeled from skipped; a skipped case is never counted as completed and
# blocks freeze. A labeled judgment records the verdict status, both bands,
# and the readiness the judge re-derived from the cited evidence; readiness
# must follow from the judged bands (no averaging across axes). A
# post-unblinding correction is appended in revised_* fields so the original
# blinded label remains the report's scoring input.
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluationLabel < ApplicationRecord
  STATES = %w[pending labeled skipped].freeze
  VERDICTS = FacetConfidence::AssessmentCorpusLedger::EXPECTED_STATUSES
  BANDS = FacetConfidence::AssessmentCorpusLedger::BANDS
  READINESS = FacetConfidence::AssessmentCorpusLedger::READINESS

  belongs_to :facet_confidence_evaluation, class_name: "FacetConfidenceEvaluation", inverse_of: :labels
  belongs_to :recorded_by, class_name: "User"
  belongs_to :revised_by, class_name: "User", optional: true

  validates :case_id, presence: true
  validates :state, inclusion: { in: STATES }
  validates :verdict, inclusion: { in: VERDICTS }, allow_nil: true
  validates :intent_band, :technical_band, inclusion: { in: BANDS }, allow_nil: true
  validates :readiness, inclusion: { in: READINESS }, allow_nil: true
  validates :verdict, :intent_band, :technical_band, :readiness,
    :cited_evidence_reference, :reason, presence: true, if: -> { state == "labeled" }
  validate :readiness_follows_bands, if: -> { state == "labeled" }
  validates :revised_verdict, inclusion: { in: VERDICTS }, allow_nil: true
  validates :revised_intent_band, :revised_technical_band, inclusion: { in: BANDS }, allow_nil: true
  validates :revised_readiness, inclusion: { in: READINESS }, allow_nil: true
  validates :revised_verdict, :revised_intent_band, :revised_technical_band, :revised_readiness,
    :revised_cited_evidence_reference, :revised_judgment_reason, :revised_reason, :revised_by, :revised_at,
    presence: true, if: :revised?
  validate :revised_readiness_follows_bands, if: :revised?

  def labeled? = state == "labeled"
  def skipped? = state == "skipped"
  def revised? = revised_verdict.present?

  def revised_judgment
    return unless revised?

    {
      "verdict" => revised_verdict,
      "intent_band" => revised_intent_band,
      "technical_band" => revised_technical_band,
      "readiness" => revised_readiness,
      "cited_evidence_reference" => revised_cited_evidence_reference,
      "reason" => revised_judgment_reason
    }
  end

  # The same structural rule the frozen corpus applies to its own
  # expectations: readiness is "ready" only when a decisive verdict puts both
  # judged bands at or above their thresholds (FACET-CONFIDENCE-009).
  def readiness_follows_bands
    return if readiness == readiness_from_bands(verdict, intent_band, technical_band)

    errors.add(:readiness, "must follow the judged bands (#{readiness_from_bands(verdict, intent_band, technical_band)})")
  end

  def revised_readiness_follows_bands
    return if revised_readiness == readiness_from_bands(revised_verdict, revised_intent_band, revised_technical_band)

    errors.add(:revised_readiness,
      "must follow the corrected bands (#{readiness_from_bands(revised_verdict, revised_intent_band, revised_technical_band)})")
  end

  private

  def readiness_from_bands(judged_verdict, judged_intent_band, judged_technical_band)
    return "ready" if judged_verdict == "completed" && judged_intent_band == "at_or_above_threshold" && judged_technical_band == "at_or_above_threshold"

    "not_ready"
  end
end
