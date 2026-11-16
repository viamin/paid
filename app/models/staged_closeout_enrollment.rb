# frozen_string_literal: true

# Explicit per-project adoption boundary for future staged closeout scheduling.
# It is intentionally separate from other project automation controls.
# @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002
class StagedCloseoutEnrollment < ApplicationRecord
  belongs_to :account
  belongs_to :project
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :staged_closeout_mappings, dependent: :restrict_with_error

  validates :project, uniqueness: true
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validate :account_matches_project
  validate :reviewer_belongs_to_account

  private

  def account_matches_project
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
  end

  def reviewer_belongs_to_account
    errors.add(:reviewed_by, "must belong to the account") if reviewed_by && account && reviewed_by.account_id != account_id
  end
end
