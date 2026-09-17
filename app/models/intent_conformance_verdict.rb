# frozen_string_literal: true

# @spec INTENT-MERGE-GUARD-002 @spec INTENT-MERGE-GUARD-003 @spec INTENT-MERGE-GUARD-004
# @spec INTENT-CONFORMANCE-REVIEW-002 @spec INTENT-CONFORMANCE-REVIEW-003
# RDR-067 intent-conformance verdict: an outcome bound to an exact PR head and
# approved design revision (so a push or design amendment recorded after the
# verdict invalidates it), plus the independent reviewer run's evidence
# (#3866) — cited design claims, cited diff locations, a reasoning summary,
# and the reviewer run/model identity. Only IntentConformance::ReviewRun
# creates these records; an implementation agent's self-report never writes
# one directly.
class IntentConformanceVerdict < ApplicationRecord
  OUTCOME_WITHIN_SCOPE = "within_scope"
  OUTCOME_MATERIAL_DRIFT = "material_drift"
  OUTCOME_UNCERTAIN = "uncertain"
  OUTCOME_NOT_EVALUATED = "not_evaluated"
  OUTCOMES = [ OUTCOME_WITHIN_SCOPE, OUTCOME_MATERIAL_DRIFT, OUTCOME_UNCERTAIN, OUTCOME_NOT_EVALUATED ].freeze

  belongs_to :project
  belongs_to :issue

  validates :pr_head_sha, presence: true
  validates :approved_design_revision, presence: true
  validates :outcome, presence: true, inclusion: { in: OUTCOMES }
  validates :recorded_at, presence: true
  validates :reviewer_run_id, presence: true
  validates :reviewer_model, presence: true

  scope :recent_first, -> { order(recorded_at: :desc, id: :desc) }

  # The most recently recorded verdict for the issue, regardless of whether
  # it is still current for today's PR head or approved design revision.
  def self.current_for(issue)
    where(issue: issue).recent_first.first
  end

  def within_scope? = outcome == OUTCOME_WITHIN_SCOPE
  def material_drift? = outcome == OUTCOME_MATERIAL_DRIFT
  def uncertain? = outcome == OUTCOME_UNCERTAIN
  def not_evaluated? = outcome == OUTCOME_NOT_EVALUATED

  # Structural identity check (RDR-067 §Merge enforcement and race safety):
  # a verdict only authorizes action on the exact head and design revision it
  # was evaluated against.
  def current_for?(pr_head_sha:, approved_design_revision:)
    self.pr_head_sha == pr_head_sha && self.approved_design_revision == approved_design_revision
  end
end
