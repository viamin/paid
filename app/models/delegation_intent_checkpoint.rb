# frozen_string_literal: true

# A RDR-080 settled-intent checkpoint: one reviewable group of the material
# product questions known for a work item before it enters delegated
# downstream work. The revision columns and grouped questions are the binding
# surface — read-only after creation — and the immutable human settlement
# lives on the append-only DelegationIntentSettlement row.
# @spec PROJECT-DELEGATION-002
class DelegationIntentCheckpoint < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending settled rejected superseded].freeze

  belongs_to :project
  belongs_to :issue
  belongs_to :feature_intent, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :settlements, class_name: "DelegationIntentSettlement", dependent: :restrict_with_error

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :design_revision, :acceptance_revision, :question_set_digest, presence: true
  validate :issue_belongs_to_project
  validate :feature_intent_belongs_to_project
  validate :question_groups_present

  # The binding is immutable: a changed revision or question set opens a new
  # checkpoint row instead of editing this one.
  attr_readonly :account_id, :project_id, :issue_id, :feature_intent_id,
                :design_revision, :acceptance_revision, :evidence_revision,
                :question_groups, :question_set_digest, :created_by_id

  scope :pending, -> { where(status: "pending") }

  def pending? = status == "pending"
  def settled? = status == "settled"
  def rejected? = status == "rejected"
  def superseded? = status == "superseded"

  # The latest settlement governs the checkpoint (one settlement per
  # checkpoint is enforced by a unique index).
  def settlement
    settlements.order(id: :desc).first
  end

  # True when the settlement's bound revisions are still the current ones,
  # i.e. downstream work may rely on the settled answers without re-asking.
  def settlement_current?(current_revisions)
    return false unless settlement

    settlement.design_revision == current_revisions["design_revision"].to_s &&
      settlement.acceptance_revision == current_revisions["acceptance_revision"].to_s
  end

  def supersede!
    update!(status: "superseded")
  end

  private

  def issue_belongs_to_project
    errors.add(:issue, "must belong to the checkpoint project") if issue && issue.project_id != project_id
  end

  def feature_intent_belongs_to_project
    errors.add(:feature_intent, "must belong to the checkpoint project") if feature_intent && feature_intent.project_id != project_id
  end

  def question_groups_present
    errors.add(:question_groups, "must include at least one grouped question") unless question_groups.is_a?(Array) && question_groups.any?
  end
end
