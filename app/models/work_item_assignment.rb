# frozen_string_literal: true

# Assigns a WorkItem to a repository-backed Paid project. Provenance records
# whether a mapping or a human produced the assignment; `locked` marks an
# issue-level customize/replace override that future mapping changes must not
# silently alter.
#
# @spec UNIFIED-WORK-ITEMS-004
class WorkItemAssignment < ApplicationRecord
  PROVENANCES = %w[mapping manual].freeze

  belongs_to :account
  belongs_to :work_item
  belongs_to :project
  belongs_to :work_item_project_mapping, optional: true
  belongs_to :assigned_by, class_name: "User", optional: true

  validates :provenance, inclusion: { in: PROVENANCES }
  validates :project_id, uniqueness: { scope: :work_item_id }
  validate :work_item_and_project_share_account

  scope :default_execution, -> { where(default_execution: true) }

  private

  def work_item_and_project_share_account
    return if work_item.nil? || project.nil?
    return if work_item.account_id == account_id && project.account_id == account_id

    errors.add(:base, "work item, project, and assignment must share the same account")
  end
end
