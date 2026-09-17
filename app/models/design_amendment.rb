# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003 @spec INTENT-AMENDMENT-004
# RDR-067 design amendment: a product-level change to an approved design that
# must route through amended RDR/LID PRs, human approval, and merge before
# affected work resumes. Impact evaluation runs when the merged revision is
# recorded (see DesignAmendments::Complete / EvaluateImpact).
class DesignAmendment < ApplicationRecord
  STATUSES = %w[open approved merged abandoned].freeze

  belongs_to :project
  belongs_to :feature_intent
  belongs_to :approved_by, class_name: "User", optional: true

  has_many :design_amendment_pauses, dependent: :destroy
  has_many :design_amendment_follow_ups, dependent: :destroy
  has_many :intent_conformance_resolutions, dependent: :nullify

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :reason, presence: true
  validates :superseded_revision, presence: true
  validate :amendment_belongs_to_feature_project

  scope :open, -> { where(status: "open") }
  scope :active, -> { where(status: %w[open approved]) }
  scope :merged, -> { where(status: "merged") }

  def open? = status == "open"
  def approved? = status == "approved"
  def merged? = status == "merged"
  def abandoned? = status == "abandoned"

  # The recorded human approval binds the amendment to the amended design PR
  # head the human reviewed; Complete refuses to record a merged revision
  # without it (INTENT-AMENDMENT-004).
  def approval_current?(merged_revision:)
    approved? &&
      approved_pr_head_sha.present? &&
      approved_at.present? &&
      approved_by_id.present? &&
      amended_revision.blank? &&
      merged_revision.to_s != superseded_revision
  end

  private

  def amendment_belongs_to_feature_project
    return if project.blank? || feature_intent.blank?
    return if feature_intent.project_id == project_id

    errors.add(:feature_intent, "must belong to the same project")
  end
end
