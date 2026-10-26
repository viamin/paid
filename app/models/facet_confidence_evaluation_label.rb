# frozen_string_literal: true

# Durable blinded reference judgment for one corpus case of a
# facet-confidence closeout evaluation. One row per (evaluation, case) so
# saves are updates-in-place and resume is free. `state` distinguishes
# labeled from skipped; a skipped case is never counted as completed and
# blocks freeze. A labeled judgment records the verdict status, both bands,
# and the readiness the judge re-derived from the cited evidence; readiness
# must follow from the judged bands (no averaging across axes).
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluationLabel < ApplicationRecord
  STATES = %w[pending labeled skipped].freeze
  VERDICTS = FacetConfidence::AssessmentCorpusLedger::EXPECTED_STATUSES
  BANDS = FacetConfidence::AssessmentCorpusLedger::BANDS
  READINESS = FacetConfidence::AssessmentCorpusLedger::READINESS

  belongs_to :facet_confidence_evaluation, class_name: "FacetConfidenceEvaluation", inverse_of: :labels
  belongs_to :recorded_by, class_name: "User"
  has_many :judgment_revisions, class_name: "FacetConfidenceEvaluationJudgmentRevision", dependent: :destroy

  validates :case_id, presence: true
  validates :state, inclusion: { in: STATES }
  validates :verdict, inclusion: { in: VERDICTS }, allow_nil: true
  validates :intent_band, :technical_band, inclusion: { in: BANDS }, allow_nil: true
  validates :readiness, inclusion: { in: READINESS }, allow_nil: true
  validates :verdict, :intent_band, :technical_band, :readiness,
    :cited_evidence_reference, :reason, presence: true, if: -> { state == "labeled" }
  validate :readiness_follows_bands, if: -> { state == "labeled" }

  def labeled? = state == "labeled"
  def skipped? = state == "skipped"

  # The same structural rule the frozen corpus applies to its own
  # expectations: readiness is "ready" only when a decisive verdict puts both
  # judged bands at or above their thresholds (FACET-CONFIDENCE-009).
  def readiness_follows_bands
    return if readiness == readiness_from_bands

    errors.add(:readiness, "must follow the judged bands (#{readiness_from_bands})")
  end

  private

  def readiness_from_bands
    return "ready" if verdict == "completed" && intent_band == "at_or_above_threshold" && technical_band == "at_or_above_threshold"

    "not_ready"
  end
end
