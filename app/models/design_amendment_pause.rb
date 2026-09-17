# frozen_string_literal: true

# @spec INTENT-AMENDMENT-006 @spec INTENT-AMENDMENT-009
# A per-branch hold applied while a design amendment's impact is resolved:
# the branch is excluded from issue selection (auto-pick, eager enqueue,
# dequeue recheck) until explicitly released.
class DesignAmendmentPause < ApplicationRecord
  REASON_CODES = %w[affected dependent uncertain].freeze
  STATUSES = %w[held released].freeze

  belongs_to :design_amendment
  belongs_to :issue
  belongs_to :released_by, class_name: "User", optional: true

  validates :reason_code, presence: true, inclusion: { in: REASON_CODES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :design_amendment_id, uniqueness: { scope: :issue_id }
  validate :issue_belongs_to_amendment_project

  scope :held, -> { where(status: "held") }
  scope :released, -> { where(status: "released") }

  # Issue ids with an active hold, scoped to a project. This is the exclusion
  # set consumed by the auto-pick candidate source; released holds drop out.
  def self.held_issue_ids(project)
    joins(:design_amendment).where(design_amendments: { project_id: project.id }).held.pluck(:issue_id)
  end

  def held? = status == "held"
  def released? = status == "released"

  private

  def issue_belongs_to_amendment_project
    return if issue.blank? || design_amendment.blank?
    return if issue.project_id == design_amendment.project_id

    errors.add(:issue, "must belong to the amendment's project")
  end
end
