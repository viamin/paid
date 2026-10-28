# frozen_string_literal: true

# Solo-maintainer RDR-067 shadow evaluation session (#4594). One row per
# evidence generation (project, purpose, frozen corpus manifest digest):
# repeated Start/Resume clicks reuse the same evaluation. The labeling
# lifecycle is labeling → frozen → queued → running → partial | failed |
# cancelled | completed; reference
# labels and reviewer runs live on the association records and answers stay
# hidden from the labeling surface until `labels_frozen_at` is set.
#
# @spec INTENT-CONFORMANCE-ROLLOUT-005
# @spec INTENT-CONFORMANCE-ROLLOUT-006
class IntentConformanceShadowEvaluation < ApplicationRecord
  EXECUTION_TIMEOUT = 15.minutes
  STATUSES = %w[labeling frozen queued running partial failed cancelled completed].freeze
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

  def labeling? = status == "labeling"
  def frozen? = !labeling?
  def queued? = status == "queued"
  def running? = status == "running"
  def partial? = status == "partial"
  def cancelled? = status == "cancelled"
  def executing? = queued? || running?
  def completed? = status == "completed"
  def failed? = status == "failed"
  def cancellation_requested? = cancellation_requested_at.present?

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

  # @spec INTENT-CONFORMANCE-ROLLOUT-011
  # The row lock makes repeated HTTP/API submissions idempotent before a job
  # can be enqueued. Completed cases stay intact for a retry/resume.
  def queue_execution!
    with_lock do
      return true if queued?
      return false if active_execution? || completed?

      update!(status: "queued", execution_enqueued_at: Time.current,
        execute_started_at: nil, cancellation_requested_at: nil,
        cancelled_at: nil, last_failure_reason: nil)
      true
    end
  end

  # Cancellation is cooperative: a running LLM call is allowed to finish,
  # then ExecuteReviewer stops before spending on the next case.
  def request_cancellation!(actor:)
    with_lock do
      return false unless queued? || running?

      if queued? || stale_execution?
        update!(status: "cancelled", cancellation_requested_at: Time.current, cancelled_at: Time.current)
      else
        update!(cancellation_requested_at: Time.current)
      end
      log_cancellation_requested(actor)
      true
    end
  end

  private

  def active_execution?
    running? && !stale_execution?
  end

  def stale_execution?
    running? && (execute_started_at.nil? || execute_started_at <= EXECUTION_TIMEOUT.ago)
  end

  def log_cancellation_requested(actor)
    Rails.logger.info(
      message: "intent_conformance.shadow_evaluation_execution_cancellation_requested",
      project_id:, shadow_evaluation_id: id, actor_user_id: actor.id,
      status:, evaluated_case_count: runs.where.not(verdict: "not_evaluated").count
    )
  end
end
