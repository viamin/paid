# frozen_string_literal: true

# Binds one review basis: the obligation revisions, the declared scope, the
# verification-plan revision, the contributing check results, the recorded
# approvals, and the Inbox decisions made while the package was open. A later
# change to any bound input creates a new package revision and retains the
# prior record. Approving a package never authorizes a repair or a release.
#
# @spec LAYERED-VERIFY-023
class LayeredVerificationReviewPackage < ApplicationRecord
  belongs_to :project
  belongs_to :agent_run
  belongs_to :approved_by, class_name: "User", optional: true

  validates :package_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :digest, presence: true
  validates :plan_revision, numericality: { only_integer: true, greater_than: 0 }
  validate :agent_run_belongs_to_same_project

  def approved?
    approved_at.present?
  end

  def bound_revisions
    Array(obligation_revisions)
  end

  def check_result_ids
    Array(check_result_references).filter_map { |reference| reference["check_result_id"] || reference[:check_result_id] }
  end

  private

  def agent_run_belongs_to_same_project
    return if agent_run.project_id == project_id

    errors.add(:agent_run, "must belong to the same project")
  end
end
