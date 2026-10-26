# frozen_string_literal: true

# Solo-maintainer RDR-067 shadow evaluation session (#4594). One row per
# evidence generation (project, purpose, frozen corpus manifest digest):
# repeated Start/Resume clicks reuse the same evaluation. The labeling
# lifecycle is labeling → frozen → executing → completed | failed; reference
# labels and reviewer runs live on the association records and answers stay
# hidden from the labeling surface until `labels_frozen_at` is set.
#
# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
class IntentConformanceShadowEvaluation < ApplicationRecord
  STATUSES = %w[labeling frozen executing completed failed].freeze
  POLICIES = IntentConformance::ShadowEvaluationPolicy::POLICIES
  OUTCOMES = IntentConformance::ShadowEvaluationPolicy::LABELS

  belongs_to :project
  belongs_to :solo_maintainer, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User"
  belongs_to :originating_issue, class_name: "Issue", optional: true
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
  def frozen? = %w[frozen executing completed failed].include?(status)
  def executing? = status == "executing"
  def completed? = status == "completed"
  def failed? = status == "failed"

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

  def corpus
    @corpus ||= IntentConformance::ShadowEvaluationCorpus.new(path: manifest_path, commit: manifest_commit, digest: manifest_digest)
  end

  def corpus_case_ids
    corpus.case_ids
  end
end
