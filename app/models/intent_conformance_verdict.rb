# frozen_string_literal: true

# Independent conformance verdict comparing a feature PR's HEAD against its
# approved design revision. See RDR-067.
#
# @spec INTENT-CONFORMANCE-001
class IntentConformanceVerdict < ApplicationRecord
  WITHIN_SCOPE = "within_scope"
  MATERIAL_DRIFT = "material_drift"
  UNCERTAIN = "uncertain"
  NOT_EVALUATED = "not_evaluated"
  OUTCOMES = [ WITHIN_SCOPE, MATERIAL_DRIFT, UNCERTAIN, NOT_EVALUATED ].freeze

  belongs_to :issue
  belongs_to :reviewer_run, class_name: "AgentRun", optional: true
  has_many :intent_conformance_decisions, foreign_key: :verdict_id, inverse_of: :verdict, dependent: :nullify

  validates :pr_head_sha, :approved_design_revision, :evaluated_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }

  # The authoritative verdict for a PR HEAD is the most recently evaluated
  # row recorded for that exact commit. A HEAD with no matching row has no
  # current verdict — a new commit or an unreviewed PR are the same case for
  # gating purposes: `nil` blocks auto-merge (@spec INTENT-CONFORMANCE-003).
  def self.current_for(issue:, head_sha:)
    return nil if head_sha.blank?

    where(issue: issue, pr_head_sha: head_sha).order(evaluated_at: :desc).first
  end

  def within_scope? = outcome == WITHIN_SCOPE
  def material_drift? = outcome == MATERIAL_DRIFT
  def uncertain? = outcome == UNCERTAIN
  def not_evaluated? = outcome == NOT_EVALUATED
end
