# frozen_string_literal: true

# Executed reviewer run for one corpus case of a shadow evaluation, recorded
# only after the reference set froze. A missing or failed reviewer output is
# persisted as `not_evaluated` with a failure reason — never counted as
# agreement with the reference label.
# @spec INTENT-CONFORMANCE-ROLLOUT-007
class IntentConformanceShadowEvaluationRun < ApplicationRecord
  VERDICTS = IntentConformance::ShadowEvaluationPolicy::LABELS + [ "not_evaluated" ].freeze

  belongs_to :shadow_evaluation, class_name: "IntentConformanceShadowEvaluation", inverse_of: :runs

  scope :evaluated, -> { where.not(verdict: "not_evaluated") }
  scope :not_evaluated, -> { where(verdict: "not_evaluated") }

  validates :case_id, presence: true
  validates :verdict, presence: true, inclusion: { in: VERDICTS }
  validates :recorded_at, presence: true
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  def evaluated? = verdict != "not_evaluated"
  def not_evaluated? = verdict == "not_evaluated"
end
