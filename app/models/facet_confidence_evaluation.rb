# frozen_string_literal: true

# Facet-confidence closeout evaluation (#4596). One row per evidence
# generation (originating issue, frozen corpus digest): repeated Start/Resume
# clicks from the same Inbox item reuse the same evaluation, and a changed
# corpus digest is a new generation that supersedes the old record rather than
# mutating it. The lifecycle is labeling → frozen; blinded reference judgments
# live on the association records and the frozen expectations stay hidden from
# the labeling surface until `labels_frozen_at` is set. The operator who
# started the evaluation (`created_by`) is its sole reference judge.
#
# @spec FACET-CONFIDENCE-020
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluation < ApplicationRecord
  STATUSES = %w[labeling frozen].freeze

  belongs_to :project
  belongs_to :issue
  belongs_to :created_by, class_name: "User"
  has_many :labels, class_name: "FacetConfidenceEvaluationLabel",
    foreign_key: :facet_confidence_evaluation_id, inverse_of: :facet_confidence_evaluation, dependent: :destroy
  has_many :label_revisions, class_name: "FacetConfidenceEvaluationLabelRevision",
    dependent: :destroy

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :corpus_path, :corpus_digest, :corpus_version, :rubric_version, :model_version, presence: true

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }

  def labeling? = status == "labeling"
  def frozen? = status == "frozen"

  def answers_visible? = labels_frozen_at.present?

  def progress
    { total: corpus_case_ids.length, labeled: labels.where(state: "labeled").count, skipped: labels.where(state: "skipped").count }
  end

  def corpus
    # Digest-keyed memo: an updated corpus_digest attribute must not keep
    # serving the stale corpus identity.
    key = [ corpus_path, corpus_digest ]
    @corpus = nil unless @corpus_key == key
    @corpus_key = key
    @corpus ||= FacetConfidence::Corpus.new(path: corpus_path, digest: corpus_digest)
  end

  def corpus_case_ids
    corpus.case_ids
  end
end
