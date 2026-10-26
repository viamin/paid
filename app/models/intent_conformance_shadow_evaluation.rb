# frozen_string_literal: true

# Solo-maintainer RDR-067 shadow evaluation session (#4594). One row per
# evidence generation (project, purpose, frozen corpus manifest digest):
# repeated Start/Resume clicks reuse the same evaluation. The labeling
# lifecycle is labeling → frozen → queued → running → completed | partial |
# failed | cancelled; reference labels and reviewer runs live on the
# association records and answers stay hidden from the labeling surface
# until `labels_frozen_at` is set. Reviewer execution runs as a background
# job whose durable progress/cancellation state this row carries (#4642);
# legacy rows may still hold the pre-async `executing` value.
#
# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class IntentConformanceShadowEvaluation < ApplicationRecord
  STATUSES = %w[labeling frozen queued running executing completed partial failed cancelled].freeze
  POLICIES = IntentConformance::ShadowEvaluationPolicy::POLICIES
  OUTCOMES = IntentConformance::ShadowEvaluationPolicy::LABELS
  # Post-freeze states from which a new execution pass may be claimed.
  RE_EXECUTABLE_STATUSES = %w[frozen completed partial failed cancelled].freeze
  NOT_EVALUATED = "not_evaluated"

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

  def labeling? = status == "labeling"
  def frozen? = %w[frozen queued running executing completed partial failed cancelled].include?(status)
  # The pre-async writer used `executing`; both values mean a worker owns the pass.
  def running? = %w[running executing].include?(status)
  def queued? = status == "queued"
  def completed? = status == "completed"
  def partial? = status == "partial"
  def failed? = status == "failed"
  def cancelled? = status == "cancelled"

  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  def execution_active? = queued? || running?

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

  # Durable execution progress and cost for the evaluation screen: per-case
  # verdicts stay on the run rows, this is the aggregate the Inbox-linked
  # surface renders for queued/running/partial passes.
  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  def execution_progress
    evaluated = runs.evaluated.count
    not_evaluated = runs.count - evaluated
    {
      total: corpus_case_ids.length,
      evaluated: evaluated,
      not_evaluated: not_evaluated,
      pending: corpus_case_ids.length - evaluated - not_evaluated,
      cost_cents: runs.evaluated.sum(:cost_cents)
    }
  end

  def corpus
    @corpus ||= IntentConformance::ShadowEvaluationCorpus.new(path: manifest_path, commit: manifest_commit, digest: manifest_digest)
  end

  def corpus_case_ids
    corpus.case_ids
  end
end
