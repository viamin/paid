# frozen_string_literal: true

class IssueDependency < ApplicationRecord
  belongs_to :issue
  belongs_to :depends_on_issue, class_name: "Issue"

  validates :depends_on_issue_id, uniqueness: { scope: :issue_id }
  validate :not_self_referential
  validate :issues_belong_to_same_project

  # Builds an adjacency map { issue_id => [depends_on_issue_id, ...] }
  # for all dependencies within a project. Used by ParseDependencies and
  # DetectCycle to avoid repeated full-table queries during batch syncs.
  def self.project_adjacency(project)
    where(issue_id: project.issues.select(:id))
      .pluck(:issue_id, :depends_on_issue_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  private

  def not_self_referential
    return unless issue_id && depends_on_issue_id
    return unless issue_id == depends_on_issue_id

    errors.add(:depends_on_issue, "cannot be the same as the issue")
  end

  def issues_belong_to_same_project
    return unless issue && depends_on_issue
    return if issue.project_id == depends_on_issue.project_id

    errors.add(:depends_on_issue, "must belong to the same project")
  end
end
