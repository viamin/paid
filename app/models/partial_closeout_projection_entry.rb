# frozen_string_literal: true

class PartialCloseoutProjectionEntry < ApplicationRecord
  belongs_to :project
  belongs_to :issue

  validates :evidence_digest, :projection_generation, presence: true
  validate :issue_belongs_to_project

  private

  def issue_belongs_to_project
    return if issue.nil? || issue.project_id == project_id

    errors.add(:issue, "must belong to the projection project")
  end
end
