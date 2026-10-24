# frozen_string_literal: true

# Durable blinded reference label for one corpus case of a shadow
# evaluation. One row per (evaluation, case) so saves are updates-in-place
# and resume is free. `state` distinguishes labeled from skipped; a skipped
# case is never counted as completed and blocks freeze. Post-result
# revisions append `revised_*` fields without touching the original outcome.
# @spec INTENT-CONFORMANCE-ROLLOUT-005 @spec INTENT-CONFORMANCE-ROLLOUT-008
class IntentConformanceShadowEvaluationLabel < ApplicationRecord
  STATES = %w[pending labeled skipped].freeze
  OUTCOMES = IntentConformance::ShadowEvaluationPolicy::LABELS

  belongs_to :shadow_evaluation, class_name: "IntentConformanceShadowEvaluation", inverse_of: :labels
  belongs_to :recorded_by, class_name: "User"
  belongs_to :revised_by, class_name: "User", optional: true

  validates :case_id, presence: true
  validates :state, inclusion: { in: STATES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :revised_outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :cited_design_claim, :reason, presence: true, if: -> { state == "labeled" }
  validates :outcome, presence: true, if: -> { state == "labeled" }
  validates :revised_reason, presence: true, if: -> { revised_outcome.present? }

  def labeled? = state == "labeled"
  def skipped? = state == "skipped"
  def revised? = revised_outcome.present?

  # The blinded score input is always the ORIGINAL label.
  def scoring_outcome
    outcome
  end
end
