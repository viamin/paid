# frozen_string_literal: true

class LayeredVerificationReviewPackage < ApplicationRecord
  # @spec LAYERED-VERIFY-023
  belongs_to :project
  belongs_to :audit_run, class_name: "AgentRun", optional: true
  belongs_to :approved_by, class_name: "User", optional: true

  validates :digest, presence: true, uniqueness: { scope: :project_id }
  validate :audit_run_belongs_to_project

  private

  def audit_run_belongs_to_project
    return if audit_run.blank? || audit_run.project_id == project_id

    errors.add(:audit_run, "must belong to the package project")
  end
end
