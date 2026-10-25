# frozen_string_literal: true

# Solo-maintainer RDR-067 shadow evaluation session (#4594). One row per
# evidence generation (project, purpose, frozen corpus manifest digest):
# repeated Start/Resume clicks reuse the same evaluation. The labeling
# lifecycle is labeling → frozen → (queued → running →)* completed |
# partial | failed | cancelled; reference labels and reviewer runs live on
# the association records and answers stay hidden from the labeling surface
# until `labels_frozen_at` is set. Reviewer execution is a queued-job
# lifecycle (#4642): retry/resume re-enters queued/running for the same
# record and only evaluates cases without an evaluated verdict.
#
# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class IntentConformanceShadowEvaluation < ApplicationRecord
  STATUSES = %w[labeling frozen queued running executing completed partial failed cancelled].freeze
  # Legacy in-flight rows written by the pre-#4642 synchronous executor are
  # still valid; recovery treats them like `running`.
  ACTIVE_EXECUTION_STATUSES = %w[queued running executing].freeze
  IDLE_EXECUTION_STATUSES = %w[frozen completed partial failed cancelled].freeze
  POLICIES = IntentConformance::ShadowEvaluationPolicy::POLICIES
  OUTCOMES = IntentConformance::ShadowEvaluationPolicy::LABELS

  belongs_to :project
  belongs_to :solo_maintainer, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User"
  has_many :labels, class_name: "IntentConformanceShadowEvaluationLabel",
    foreign_key: :shadow_evaluation_id, inverse_of: :shadow_evaluation, dependent: :destroy
  has_many :runs, class_name: "IntentConformanceShadowEvaluationRun",
    foreign_key: :shadow_evaluation_id, inverse_of: :shadow_evaluation, dependent: :destroy

  validates :policy, presence: true, inclusion: { in: POLICIES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :manifest_path, presence: true
  validates :solo_maintainer, presence: true, if: -> { policy == "solo" }
  validates :purpose, presence: true

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }
  scope :queued, -> { where(status: "queued") }
  scope :running, -> { where(status: %w[running executing]) }

  def labeling? = status == "labeling"
  def frozen? = IDLE_EXECUTION_STATUSES.include?(status)
  def queued? = status == "queued"
  # `executing` is the pre-#4642 spelling of running; both mean a worker
  # owns (or owned) the in-flight execution.
  def running? = %w[running executing].include?(status)
  def completed? = status == "completed"
  def partial? = status == "partial"
  def failed? = status == "failed"
  def cancelled? = status == "cancelled"
  def execution_active? = ACTIVE_EXECUTION_STATUSES.include?(status)
  def cancel_requested? = cancel_requested_at.present?

  def answers_visible? = labels_frozen_at.present?

  # Blinding boundary: reviewer outputs exist only after freeze, so any
  # labeling-surface query through this evaluation is structurally blind.
  def blinded? = !answers_visible?

  def labeled_case_ids
    labels.where(state: "labeled").pluck(:case_id).index_with { true }
  end

  def progress
    { total: corpus_case_ids.length, labeled: labels.where(state: "labeled").count, skipped: labels.where(state: "skipped").count }
  end

  # Durable execution progress from the persisted run rows: count-only by
  # verdict state plus recorded reviewer cost, so the evaluation surface can
  # show progress while the job runs and after interruption/cancellation
  # without re-deriving anything semantic (#4642).
  def execution_progress
    total = corpus_case_ids.length
    rows = runs.where(case_id: corpus_case_ids).pluck(:verdict, :cost_cents)
    evaluated = rows.count { |verdict, _cost| verdict != "not_evaluated" }
    { total: total, evaluated: evaluated, not_evaluated: rows.length - evaluated,
      cost_cents: rows.sum { |_verdict, cost| cost.to_i } }
  end

  def corpus
    @corpus ||= IntentConformance::ShadowEvaluationCorpus.new(path: manifest_path, commit: manifest_commit, digest: manifest_digest)
  end

  def corpus_case_ids
    corpus.case_ids
  end
end
