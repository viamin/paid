# frozen_string_literal: true

# @spec INTENT-AMENDMENT-008
# A follow-up human decision for already-merged work affected by a design
# revision. Created instead of any automatic rollback: only a human records
# the decision (keep, amend further, revert manually, ...).
class DesignAmendmentFollowUp < ApplicationRecord
  STATUSES = %w[open resolved].freeze

  belongs_to :design_amendment
  belongs_to :issue
  belongs_to :decided_by, class_name: "User", optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :design_amendment_id, uniqueness: { scope: :issue_id }
  validate :issue_belongs_to_amendment_project
  validate :decision_complete_when_resolved

  scope :open, -> { where(status: "open") }
  scope :resolved, -> { where(status: "resolved") }

  def open? = status == "open"
  def resolved? = status == "resolved"

  # Records the human's follow-up decision. Merged work is never touched
  # automatically; this is the only state transition a follow-up has.
  def resolve!(actor:, decision:)
    update!(status: "resolved", decided_by: actor, decision: decision, decided_at: Time.current)
  end

  private

  def issue_belongs_to_amendment_project
    return if issue.blank? || design_amendment.blank?
    return if issue.project_id == design_amendment.project_id

    errors.add(:issue, "must belong to the amendment's project")
  end

  def decision_complete_when_resolved
    return unless status == "resolved"
    return if decision.present? && decided_by_id.present?

    errors.add(:decision, "must record the decision and deciding human when resolved")
  end
end
